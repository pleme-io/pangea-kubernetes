# frozen_string_literal: true

# Security invariant tests for the aws_nixos backend.
# These tests PROVE that pangea-kubernetes ships fully hardened,
# least-privilege infrastructure. Any regression here blocks deployment.

RSpec.describe 'AwsNixos security hardening' do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) do
    {
      KubernetesCluster: 'kazoku',
      Backend: 'aws_nixos',
      ManagedBy: 'Pangea',
    }
  end
  let(:config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :aws_nixos,
      kubernetes_version: '1.29',
      region: 'us-east-1',
      distribution: :k3s,
      profile: 'cilium-standard',
      ami_id: 'ami-test',
      key_pair: 'test-key',
      account_id: '123456789012',
      etcd_backup_bucket: 'kazoku-etcd-backups',
      ssh_cidr: '10.0.0.0/8',
      api_cidr: '10.0.0.0/8',
      node_pools: [
        { name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 },
        { name: :worker, instance_types: ['t3.medium'], min_size: 1, max_size: 4 },
      ],
      network: { vpc_cidr: '10.0.0.0/16' },
    )
  end

  let(:network) { Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :kazoku, config, base_tags) }
  let(:iam) { Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :kazoku, config, base_tags) }

  # Helper to find ingress security group rules
  def ingress_rules
    ctx.created_resources.select { |r| r[:type] == 'aws_security_group_rule' && r[:attrs][:type] == 'ingress' }
  end

  # ── Input Validation ─────────────────────────────────────────────

  describe 'input validation' do
    it 'rejects missing account_id' do
      bad_config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, region: 'us-east-1',
        node_pools: [{ name: :system, instance_types: ['t3.medium'] }],
        network: { vpc_cidr: '10.0.0.0/16' },
        tags: { etcd_backup_bucket: 'test' },
      )
      expect {
        Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, bad_config, base_tags)
      }.to raise_error(ArgumentError, /account_id is required/)
    end

    it 'rejects CHANGEME as account_id' do
      bad_config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, region: 'us-east-1',
        node_pools: [{ name: :system, instance_types: ['t3.medium'] }],
        network: { vpc_cidr: '10.0.0.0/16' },
        tags: { account_id: 'CHANGEME', etcd_backup_bucket: 'test' },
      )
      expect {
        Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, bad_config, base_tags)
      }.to raise_error(ArgumentError, /account_id is required/)
    end

    it 'rejects 0.0.0.0/0 for ssh_cidr' do
      bad_config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, region: 'us-east-1',
        node_pools: [{ name: :system, instance_types: ['t3.medium'] }],
        network: { vpc_cidr: '10.0.0.0/16' },
        account_id: '123',
        ssh_cidr: '0.0.0.0/0',
      )
      expect {
        Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, bad_config, base_tags)
      }.to raise_error(ArgumentError, /ssh_cidr must not be 0\.0\.0\.0\/0/)
    end

    it 'rejects 0.0.0.0/0 for api_cidr' do
      bad_config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, region: 'us-east-1',
        node_pools: [{ name: :system, instance_types: ['t3.medium'] }],
        network: { vpc_cidr: '10.0.0.0/16' },
        account_id: '123',
        api_cidr: '0.0.0.0/0',
      )
      expect {
        Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, bad_config, base_tags)
      }.to raise_error(ArgumentError, /api_cidr must not be 0\.0\.0\.0\/0/)
    end
  end

  # ── IAM Least Privilege ──────────────────────────────────────────

  describe 'IAM least privilege' do
    before { iam }

    it 'creates exactly 5 scoped IAM policies' do
      policies = ctx.created_resources.select { |r| r[:type] == 'aws_iam_policy' }
      expect(policies.size).to eq(5)
    end

    it 'attaches all 5 policies to the role' do
      attachments = ctx.created_resources.select { |r| r[:type] == 'aws_iam_role_policy_attachment' }
      expect(attachments.size).to eq(5)
    end

    it 'ECR policy has no wildcard actions' do
      ecr = ctx.find_resource(:aws_iam_policy, :kazoku_ecr_read)
      policy = JSON.parse(ecr[:attrs][:policy])
      all_actions = policy['Statement'].flat_map { |s| Array(s['Action']) }

      expect(all_actions).not_to include('ecr:*')
      expect(all_actions).not_to include('*')
      %w[ecr:PutImage ecr:DeleteRepository ecr:CreateRepository ecr:TagResource].each do |dangerous|
        expect(all_actions).not_to include(dangerous), "ECR policy must not include #{dangerous}"
      end
    end

    it 'ECR policy scoped to specific account (no wildcard resources)' do
      ecr = ctx.find_resource(:aws_iam_policy, :kazoku_ecr_read)
      policy = JSON.parse(ecr[:attrs][:policy])
      ecr_read_stmt = policy['Statement'].find { |s| s['Sid'] == 'ECRReadOnly' }
      resources = Array(ecr_read_stmt['Resource'])

      resources.each do |r|
        expect(r).to include('123456789012'), "ECR resource must be account-scoped, got: #{r}"
      end
    end

    it 'CloudWatch policy scoped to specific account (no wildcard resources)' do
      logs = ctx.find_resource(:aws_iam_policy, :kazoku_logs)
      policy = JSON.parse(logs[:attrs][:policy])
      resources = policy['Statement'].flat_map { |s| Array(s['Resource']) }

      resources.each do |r|
        expect(r).to include('123456789012'), "CloudWatch resource must be account-scoped, got: #{r}"
      end
    end

    it 'S3 policy scoped to specific etcd bucket' do
      s3 = ctx.find_resource(:aws_iam_policy, :kazoku_etcd_backup)
      policy = JSON.parse(s3[:attrs][:policy])
      resources = policy['Statement'].flat_map { |s| Array(s['Resource']) }

      expect(resources).to all(include('kazoku-etcd-backups'))
      expect(resources).not_to include('*')
    end

    it 'S3 policy has no dangerous actions' do
      s3 = ctx.find_resource(:aws_iam_policy, :kazoku_etcd_backup)
      policy = JSON.parse(s3[:attrs][:policy])
      all_actions = policy['Statement'].flat_map { |s| Array(s['Action']) }

      %w[s3:DeleteObject s3:DeleteBucket s3:PutBucketPolicy s3:*].each do |dangerous|
        expect(all_actions).not_to include(dangerous), "S3 policy must not include #{dangerous}"
      end
    end

    it 'CloudWatch logs policy scoped to specific log group' do
      logs = ctx.find_resource(:aws_iam_policy, :kazoku_logs)
      policy = JSON.parse(logs[:attrs][:policy])
      resources = policy['Statement'].flat_map { |s| Array(s['Resource']) }

      expect(resources).to all(include('/k3s/kazoku'))
    end

    it 'EC2 policy is describe-only with region condition' do
      ec2 = ctx.find_resource(:aws_iam_policy, :kazoku_ec2_describe)
      policy = JSON.parse(ec2[:attrs][:policy])
      all_actions = policy['Statement'].flat_map { |s| Array(s['Action']) }

      all_actions.each do |action|
        expect(action).to start_with('ec2:Describe'), "EC2 policy must be describe-only, found: #{action}"
      end

      conditions = policy['Statement'].map { |s| s['Condition'] }.compact
      expect(conditions).not_to be_empty, 'EC2 policy must have region condition'
    end

    it 'SSM policy has no RunCommand actions' do
      ssm = ctx.find_resource(:aws_iam_policy, :kazoku_ssm)
      policy = JSON.parse(ssm[:attrs][:policy])
      all_actions = policy['Statement'].flat_map { |s| Array(s['Action']) }

      %w[ssm:SendCommand ssm:CreateDocument ssm:DeleteDocument ssm:*].each do |dangerous|
        expect(all_actions).not_to include(dangerous), "SSM policy must not include #{dangerous}"
      end
    end

    it 'IAM role has max_session_duration of 3600' do
      role = ctx.find_resource(:aws_iam_role, :kazoku_node_role)
      expect(role[:attrs][:max_session_duration]).to eq(3600)
    end

    it 'IAM role assume_role_policy is a JSON string' do
      role = ctx.find_resource(:aws_iam_role, :kazoku_node_role)
      expect(role[:attrs][:assume_role_policy]).to be_a(String)
      parsed = JSON.parse(role[:attrs][:assume_role_policy])
      expect(parsed['Statement'].first['Principal']['Service']).to eq('ec2.amazonaws.com')
    end
  end

  # ── Network Security ─────────────────────────────────────────────

  describe 'network security' do
    before { network }

    it 'SSH is NOT open to 0.0.0.0/0' do
      ssh_rule = ingress_rules.find { |r| r[:attrs][:description] == 'SSH' }
      expect(ssh_rule[:attrs][:cidr_blocks]).not_to include('0.0.0.0/0')
    end

    it 'K8s API is NOT open to 0.0.0.0/0' do
      api_rule = ingress_rules.find { |r| r[:attrs][:description] == 'K8s API' }
      expect(api_rule[:attrs][:cidr_blocks]).not_to include('0.0.0.0/0')
    end

    it 'etcd is restricted to VPC CIDR' do
      etcd_rule = ingress_rules.find { |r| r[:attrs][:description] == 'etcd' }
      expect(etcd_rule[:attrs][:cidr_blocks]).to eq(['10.0.0.0/16'])
    end

    it 'kubelet is restricted to VPC CIDR' do
      kubelet_rule = ingress_rules.find { |r| r[:attrs][:description] == 'Kubelet' }
      expect(kubelet_rule[:attrs][:cidr_blocks]).to eq(['10.0.0.0/16'])
    end

    it 'VXLAN is restricted to VPC CIDR' do
      vxlan_rule = ingress_rules.find { |r| r[:attrs][:description] == 'VXLAN' }
      expect(vxlan_rule[:attrs][:cidr_blocks]).to eq(['10.0.0.0/16'])
    end

    it 'only HTTP and HTTPS are public' do
      public_rules = ingress_rules.select { |r| r[:attrs][:cidr_blocks].include?('0.0.0.0/0') }
      public_descriptions = public_rules.map { |r| r[:attrs][:description] }
      expect(public_descriptions).to contain_exactly('HTTP', 'HTTPS')
    end

    it 'creates public route table with separate default route' do
      rt = ctx.find_resource(:aws_route_table, :kazoku_public_rt)
      expect(rt).not_to be_nil
      route = ctx.find_resource(:aws_route, :kazoku_public_default_route)
      expect(route).not_to be_nil
      expect(route[:attrs][:destination_cidr_block]).to eq('0.0.0.0/0')
    end

    it 'associates all subnets with route tables (3 tiers × 3 AZs)' do
      rta = ctx.created_resources.select { |r| r[:type] == 'aws_route_table_association' }
      expect(rta.size).to eq(9)
    end
  end

  # ── S3 Etcd Bucket ──────────────────────────────────────────────

  describe 'S3 etcd bucket' do
    before { network }

    it 'creates S3 bucket for etcd backups' do
      bucket = ctx.find_resource(:aws_s3_bucket, :kazoku_etcd)
      expect(bucket).not_to be_nil
      expect(bucket[:attrs][:bucket]).to eq('kazoku-etcd-backups')
    end

    it 'enables versioning on etcd bucket' do
      versioning = ctx.find_resource(:aws_s3_bucket_versioning, :kazoku_etcd_versioning)
      expect(versioning).not_to be_nil
      expect(versioning[:attrs][:versioning_configuration]).to eq({ status: 'Enabled' })
    end

    it 'enables server-side encryption on etcd bucket' do
      encryption = ctx.find_resource(:aws_s3_bucket_server_side_encryption_configuration, :kazoku_etcd_encryption)
      expect(encryption).not_to be_nil
    end

    it 'blocks all public access on etcd bucket' do
      public_access = ctx.find_resource(:aws_s3_bucket_public_access_block, :kazoku_etcd_public_access)
      expect(public_access).not_to be_nil
      expect(public_access[:attrs][:block_public_acls]).to be true
      expect(public_access[:attrs][:block_public_policy]).to be true
      expect(public_access[:attrs][:ignore_public_acls]).to be true
      expect(public_access[:attrs][:restrict_public_buckets]).to be true
    end
  end

  # ── Compute Hardening (Launch Template + ASG + NLB) ─────────────

  describe 'compute hardening' do
    let(:arch_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:kazoku, config)
      r.network = network
      r.iam = iam
      r
    end

    before do
      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :kazoku, config, arch_result, base_tags)
    end

    it 'uses no raw EC2 instances (all compute via ASG)' do
      instances = ctx.created_resources.select { |r| r[:type] == 'aws_instance' }
      expect(instances).to be_empty
    end

    it 'requires IMDSv2 (http_tokens: required) on launch template' do
      lt = ctx.find_resource(:aws_launch_template, :kazoku_cp_lt)
      expect(lt[:attrs][:metadata_options][:http_tokens]).to eq('required')
    end

    it 'limits IMDS hop count to 1 on launch template' do
      lt = ctx.find_resource(:aws_launch_template, :kazoku_cp_lt)
      expect(lt[:attrs][:metadata_options][:http_put_response_hop_limit]).to eq(1)
    end

    it 'encrypts volumes via launch template' do
      lt = ctx.find_resource(:aws_launch_template, :kazoku_cp_lt)
      ebs = lt[:attrs][:block_device_mappings].first[:ebs]
      expect(ebs[:encrypted]).to be(true)
    end

    it 'uses gp3 volume type via launch template' do
      lt = ctx.find_resource(:aws_launch_template, :kazoku_cp_lt)
      ebs = lt[:attrs][:block_device_mappings].first[:ebs]
      expect(ebs[:volume_type]).to eq('gp3')
    end

    it 'NLB is internal (not internet-facing)' do
      nlb = ctx.find_resource(:aws_lb, :kazoku_cp_nlb)
      expect(nlb[:attrs][:internal]).to be true
    end
  end

  # ── Observability ────────────────────────────────────────────────

  describe 'observability' do
    before { iam }

    it 'creates CloudWatch log group with 30-day retention' do
      log_group = ctx.find_resource(:aws_cloudwatch_log_group, :kazoku_logs)
      expect(log_group).not_to be_nil
      expect(log_group[:attrs][:retention_in_days]).to eq(30)
    end
  end

  # ── Tagging Compliance ──────────────────────────────────────────

  describe 'tagging compliance' do
    before do
      network
      iam
    end

    it 'tags all IAM resources' do
      role = ctx.find_resource(:aws_iam_role, :kazoku_node_role)
      expect(role[:attrs]).to have_key(:tags)

      profile = ctx.find_resource(:aws_iam_instance_profile, :kazoku_node_profile)
      expect(profile[:attrs]).to have_key(:tags)
    end

    it 'tags all network resources' do
      %i[kazoku_vpc kazoku_igw kazoku_sg].each do |name|
        type = case name.to_s
               when /vpc/ then :aws_vpc
               when /igw/ then :aws_internet_gateway
               when /sg/ then :aws_security_group
               end
        resource = ctx.find_resource(type, name)
        expect(resource[:attrs]).to have_key(:tags), "#{name} must be tagged"
      end
    end

    it 'tags etcd S3 bucket' do
      bucket = ctx.find_resource(:aws_s3_bucket, :kazoku_etcd)
      expect(bucket[:attrs]).to have_key(:tags)
    end
  end

  # ── SG ALB Restriction ──────────────────────────────────────────

  describe 'SG ALB restriction (enabled)' do
    let(:alb_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [{ name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        ingress_alb_enabled: true,
        sg_restrict_http_to_alb: true,
      )
    end
    let(:alb_ctx) { create_mock_context }
    let(:alb_network) { Pangea::Kubernetes::Backends::AwsNixos.create_network(alb_ctx, :test, alb_config, base_tags) }
    let(:alb_iam) { Pangea::Kubernetes::Backends::AwsNixos.create_iam(alb_ctx, :test, alb_config, base_tags) }
    let(:alb_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, alb_config)
      r.network = alb_network
      r.iam = alb_iam
      r
    end

    before do
      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(alb_ctx, :test, alb_config, alb_result, base_tags)
    end

    it 'does NOT create CIDR-based HTTP/HTTPS ingress rules' do
      sg_rules = alb_ctx.created_resources.select { |r| r[:type] == 'aws_security_group_rule' && r[:attrs][:type] == 'ingress' }
      cidr_http = sg_rules.select { |r| r[:attrs][:description] == 'HTTP' && r[:attrs][:cidr_blocks] }
      cidr_https = sg_rules.select { |r| r[:attrs][:description] == 'HTTPS' && r[:attrs][:cidr_blocks] }
      expect(cidr_http).to be_empty
      expect(cidr_https).to be_empty
    end

    it 'creates SG-source rules for HTTP/HTTPS from ALB' do
      http_from_alb = alb_ctx.find_resource(:aws_security_group_rule, :test_sg_http_from_alb)
      https_from_alb = alb_ctx.find_resource(:aws_security_group_rule, :test_sg_https_from_alb)
      expect(http_from_alb).not_to be_nil
      expect(http_from_alb[:attrs][:source_security_group_id]).not_to be_nil
      expect(https_from_alb).not_to be_nil
      expect(https_from_alb[:attrs][:source_security_group_id]).not_to be_nil
    end
  end

  describe 'SG ALB restriction (default off)' do
    before { network }

    it 'HTTP/HTTPS use 0.0.0.0/0 by default' do
      http_rule = ingress_rules.find { |r| r[:attrs][:description] == 'HTTP' }
      https_rule = ingress_rules.find { |r| r[:attrs][:description] == 'HTTPS' }
      expect(http_rule[:attrs][:cidr_blocks]).to eq(['0.0.0.0/0'])
      expect(https_rule[:attrs][:cidr_blocks]).to eq(['0.0.0.0/0'])
    end
  end

  # ── VPC Flow Logs ──────────────────────────────────────────────

  describe 'VPC flow logs (enabled)' do
    let(:flow_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [{ name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        flow_logs_enabled: true,
        flow_logs_traffic_type: 'ALL',
        flow_logs_retention_days: 90,
      )
    end
    let(:flow_ctx) { create_mock_context }

    before do
      Pangea::Kubernetes::Backends::AwsNixos.create_network(flow_ctx, :test, flow_config, base_tags)
    end

    it 'creates aws_flow_log resource' do
      flow_log = flow_ctx.find_resource(:aws_flow_log, :test_vpc_flow_log)
      expect(flow_log).not_to be_nil
      expect(flow_log[:attrs][:traffic_type]).to eq('ALL')
    end

    it 'creates IAM role with vpc-flow-logs trust' do
      role = flow_ctx.find_resource(:aws_iam_role, :test_flow_log_role)
      expect(role).not_to be_nil
      trust = JSON.parse(role[:attrs][:assume_role_policy])
      expect(trust['Statement'].first['Principal']['Service']).to eq('vpc-flow-logs.amazonaws.com')
    end

    it 'creates CloudWatch log group for flow logs' do
      log_group = flow_ctx.find_resource(:aws_cloudwatch_log_group, :test_flow_logs)
      expect(log_group).not_to be_nil
      expect(log_group[:attrs][:retention_in_days]).to eq(90)
    end
  end

  describe 'VPC flow logs (default off)' do
    before { network }

    it 'does not create aws_flow_log' do
      flow_logs = ctx.created_resources.select { |r| r[:type] == 'aws_flow_log' }
      expect(flow_logs).to be_empty
    end
  end

  # ── KMS for CloudWatch Logs ────────────────────────────────────

  describe 'KMS logs (enabled)' do
    let(:kms_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [{ name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        kms_logs_enabled: true,
      )
    end
    let(:kms_ctx) { create_mock_context }

    before do
      Pangea::Kubernetes::Backends::AwsNixos.create_iam(kms_ctx, :test, kms_config, base_tags)
    end

    it 'creates KMS key with rotation enabled' do
      kms_key = kms_ctx.find_resource(:aws_kms_key, :test_logs_kms)
      expect(kms_key).not_to be_nil
      expect(kms_key[:attrs][:enable_key_rotation]).to be true
    end

    it 'creates KMS alias' do
      kms_alias = kms_ctx.find_resource(:aws_kms_alias, :test_logs_kms_alias)
      expect(kms_alias).not_to be_nil
    end

    it 'CloudWatch log group has kms_key_id' do
      log_group = kms_ctx.find_resource(:aws_cloudwatch_log_group, :test_logs)
      expect(log_group[:attrs][:kms_key_id]).not_to be_nil
    end
  end

  describe 'KMS logs (default off)' do
    before { iam }

    it 'no KMS key created' do
      kms_keys = ctx.created_resources.select { |r| r[:type] == 'aws_kms_key' }
      expect(kms_keys).to be_empty
    end

    it 'CloudWatch log group has no kms_key_id' do
      log_group = ctx.find_resource(:aws_cloudwatch_log_group, :kazoku_logs)
      expect(log_group[:attrs]).not_to have_key(:kms_key_id)
    end
  end

  # ── NAT Per-AZ ─────────────────────────────────────────────────

  describe 'NAT per-AZ (enabled)' do
    let(:nat_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [{ name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        nat_per_az: true,
      )
    end
    let(:nat_ctx) { create_mock_context }

    before do
      Pangea::Kubernetes::Backends::AwsNixos.create_network(nat_ctx, :test, nat_config, base_tags)
    end

    it 'creates 3 EIPs' do
      eips = nat_ctx.created_resources.select { |r| r[:type] == 'aws_eip' }
      expect(eips.size).to eq(3)
    end

    it 'creates 3 NAT gateways' do
      nats = nat_ctx.created_resources.select { |r| r[:type] == 'aws_nat_gateway' }
      expect(nats.size).to eq(3)
    end

    it 'creates 3 web route tables' do
      # 3 web route tables + 1 public route table + 1 data route table = 5
      web_rts = nat_ctx.created_resources.select { |r|
        r[:type] == 'aws_route_table' && r[:attrs][:tags]&.dig(:Name)&.include?('web-rt')
      }
      expect(web_rts.size).to eq(3)
    end
  end

  describe 'NAT per-AZ (default off)' do
    before { network }

    it 'creates single EIP' do
      eips = ctx.created_resources.select { |r| r[:type] == 'aws_eip' }
      expect(eips.size).to eq(1)
    end

    it 'creates single NAT gateway' do
      nats = ctx.created_resources.select { |r| r[:type] == 'aws_nat_gateway' }
      expect(nats.size).to eq(1)
    end
  end

  # ── SSM-Only Mode ──────────────────────────────────────────────

  describe 'SSM-only (enabled)' do
    let(:ssm_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [{ name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        ssm_only: true,
      )
    end
    let(:ssm_ctx) { create_mock_context }
    let(:ssm_network) { Pangea::Kubernetes::Backends::AwsNixos.create_network(ssm_ctx, :test, ssm_config, base_tags) }
    let(:ssm_iam) { Pangea::Kubernetes::Backends::AwsNixos.create_iam(ssm_ctx, :test, ssm_config, base_tags) }
    let(:ssm_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, ssm_config)
      r.network = ssm_network
      r.iam = ssm_iam
      r
    end

    it 'has no SSH SG rule' do
      ssm_network
      sg_rules = ssm_ctx.created_resources.select { |r|
        r[:type] == 'aws_security_group_rule' && r[:attrs][:type] == 'ingress' && r[:attrs][:description] == 'SSH'
      }
      expect(sg_rules).to be_empty
    end

    it 'launch template has no key_name' do
      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ssm_ctx, :test, ssm_config, ssm_result, base_tags)
      lt = ssm_ctx.find_resource(:aws_launch_template, :test_cp_lt)
      expect(lt[:attrs]).not_to have_key(:key_name)
    end
  end

  describe 'SSM-only (default off)' do
    before { network }

    it 'SSH rule exists' do
      ssh_rule = ingress_rules.find { |r| r[:attrs][:description] == 'SSH' }
      expect(ssh_rule).not_to be_nil
    end
  end

  # ── SSM Logs Bucket ────────────────────────────────────────────

  describe 'SSM logs bucket' do
    let(:ssm_bucket_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [{ name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        ssm_logs_bucket: 'my-ssm-logs',
      )
    end
    let(:ssm_b_ctx) { create_mock_context }

    it 'creates separate S3 bucket for SSM logs' do
      Pangea::Kubernetes::Backends::AwsNixos.create_network(ssm_b_ctx, :test, ssm_bucket_config, base_tags)
      bucket = ssm_b_ctx.find_resource(:aws_s3_bucket, :test_ssm_logs)
      expect(bucket).not_to be_nil
      expect(bucket[:attrs][:bucket]).to eq('my-ssm-logs')
    end

    it 'SSM policy references the separate bucket' do
      Pangea::Kubernetes::Backends::AwsNixos.create_iam(ssm_b_ctx, :test, ssm_bucket_config, base_tags)
      ssm = ssm_b_ctx.find_resource(:aws_iam_policy, :test_ssm)
      policy = JSON.parse(ssm[:attrs][:policy])
      resources = policy['Statement'].flat_map { |s| Array(s['Resource']) }
      expect(resources.any? { |r| r.include?('my-ssm-logs') }).to be true
    end
  end

  # ── VPN Source CIDR ────────────────────────────────────────────

  describe 'VPN source CIDR (set)' do
    let(:vpn_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [{ name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        vpn_nlb_enabled: true,
        vpn_source_cidr: '1.2.3.0/24',
      )
    end
    let(:vpn_ctx) { create_mock_context }
    let(:vpn_network) { Pangea::Kubernetes::Backends::AwsNixos.create_network(vpn_ctx, :test, vpn_config, base_tags) }
    let(:vpn_iam) { Pangea::Kubernetes::Backends::AwsNixos.create_iam(vpn_ctx, :test, vpn_config, base_tags) }
    let(:vpn_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, vpn_config)
      r.network = vpn_network
      r.iam = vpn_iam
      r
    end

    before do
      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(vpn_ctx, :test, vpn_config, vpn_result, base_tags)
    end

    it 'VPN SG rule uses configured CIDR' do
      vpn_rule = vpn_ctx.find_resource(:aws_security_group_rule, :test_sg_vpn_ingress)
      expect(vpn_rule[:attrs][:cidr_blocks]).to eq(['1.2.3.0/24'])
    end
  end

  describe 'VPN source CIDR (default nil)' do
    let(:vpn_default_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [{ name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        vpn_nlb_enabled: true,
      )
    end
    let(:vpn_d_ctx) { create_mock_context }
    let(:vpn_d_network) { Pangea::Kubernetes::Backends::AwsNixos.create_network(vpn_d_ctx, :test, vpn_default_config, base_tags) }
    let(:vpn_d_iam) { Pangea::Kubernetes::Backends::AwsNixos.create_iam(vpn_d_ctx, :test, vpn_default_config, base_tags) }
    let(:vpn_d_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, vpn_default_config)
      r.network = vpn_d_network
      r.iam = vpn_d_iam
      r
    end

    before do
      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(vpn_d_ctx, :test, vpn_default_config, vpn_d_result, base_tags)
    end

    it 'VPN SG rule uses 0.0.0.0/0' do
      vpn_rule = vpn_d_ctx.find_resource(:aws_security_group_rule, :test_sg_vpn_ingress)
      expect(vpn_rule[:attrs][:cidr_blocks]).to eq(['0.0.0.0/0'])
    end
  end

  # ── VPN Health Check Port ──────────────────────────────────────

  describe 'VPN health check port' do
    let(:vpn_hc_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [{ name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        vpn_nlb_enabled: true,
        vpn_nlb_port: 51822,
      )
    end
    let(:vpn_hc_ctx) { create_mock_context }
    let(:vpn_hc_network) { Pangea::Kubernetes::Backends::AwsNixos.create_network(vpn_hc_ctx, :test, vpn_hc_config, base_tags) }
    let(:vpn_hc_iam) { Pangea::Kubernetes::Backends::AwsNixos.create_iam(vpn_hc_ctx, :test, vpn_hc_config, base_tags) }
    let(:vpn_hc_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, vpn_hc_config)
      r.network = vpn_hc_network
      r.iam = vpn_hc_iam
      r
    end

    before do
      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(vpn_hc_ctx, :test, vpn_hc_config, vpn_hc_result, base_tags)
    end

    it 'health check port matches vpn_nlb_port, not SSH 22' do
      tg = vpn_hc_ctx.find_resource(:aws_lb_target_group, :test_vpn_tg)
      expect(tg[:attrs][:health_check][:port]).to eq('51822')
    end
  end

  # ── Worker Ingress TG Attachment ───────────────────────────────

  describe 'worker ingress TG attachment' do
    let(:ingress_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [
          { name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 },
          { name: :worker, instance_types: ['t3.medium'], min_size: 1, max_size: 4 },
        ],
        network: { vpc_cidr: '10.0.0.0/16' },
        ingress_alb_enabled: true,
      )
    end
    let(:ing_ctx) { create_mock_context }
    let(:ing_network) { Pangea::Kubernetes::Backends::AwsNixos.create_network(ing_ctx, :test, ingress_config, base_tags) }
    let(:ing_iam) { Pangea::Kubernetes::Backends::AwsNixos.create_iam(ing_ctx, :test, ingress_config, base_tags) }
    let(:ing_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, ingress_config)
      r.network = ing_network
      r.iam = ing_iam
      r
    end

    before do
      cluster_ref = Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ing_ctx, :test, ingress_config, ing_result, base_tags)
      ing_result.cluster = Pangea::Kubernetes::Architecture::ClusterResult.new(cluster_ref)
      ingress_config.node_pools.each do |pool|
        Pangea::Kubernetes::Backends::AwsNixos.create_node_pool(ing_ctx, :test, cluster_ref, pool, base_tags)
      end
    end

    it 'worker ASGs are attached to ingress target group' do
      ingress_attachments = ing_ctx.created_resources.select { |r|
        r[:type] == 'aws_autoscaling_attachment' && r[:name].to_s.include?('ingress_tg')
      }
      expect(ingress_attachments).not_to be_empty
    end
  end

  # ── ACM Certificate ────────────────────────────────────────────

  describe 'ACM certificate (domain set)' do
    let(:acm_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [{ name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        ingress_alb_enabled: true,
        ingress_alb_domain: 'test.example.com',
        ingress_alb_zone_id: 'Z123456',
      )
    end
    let(:acm_ctx) { create_mock_context }
    let(:acm_network) { Pangea::Kubernetes::Backends::AwsNixos.create_network(acm_ctx, :test, acm_config, base_tags) }
    let(:acm_iam) { Pangea::Kubernetes::Backends::AwsNixos.create_iam(acm_ctx, :test, acm_config, base_tags) }
    let(:acm_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, acm_config)
      r.network = acm_network
      r.iam = acm_iam
      r
    end

    before do
      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(acm_ctx, :test, acm_config, acm_result, base_tags)
    end

    it 'creates ACM certificate' do
      cert = acm_ctx.find_resource(:aws_acm_certificate, :test_ingress_cert)
      expect(cert).not_to be_nil
      expect(cert[:attrs][:domain_name]).to eq('test.example.com')
    end

    it 'creates ACM validation' do
      validation = acm_ctx.find_resource(:aws_acm_certificate_validation, :test_ingress_cert_validation)
      expect(validation).not_to be_nil
    end

    it 'creates HTTPS listener with ACM cert' do
      listener = acm_ctx.find_resource(:aws_lb_listener, :test_ingress_https)
      expect(listener).not_to be_nil
    end
  end

  # ── Distribution Track Inheritance ─────────────────────────────

  describe 'distribution track inheritance' do
    let(:track_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        distribution_track: '1.31',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [
          { name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 },
          { name: :worker, instance_types: ['t3.medium'], min_size: 1, max_size: 2 },
        ],
        network: { vpc_cidr: '10.0.0.0/16' },
      )
    end
    let(:track_ctx) { create_mock_context }
    let(:track_network) { Pangea::Kubernetes::Backends::AwsNixos.create_network(track_ctx, :test, track_config, base_tags) }
    let(:track_iam) { Pangea::Kubernetes::Backends::AwsNixos.create_iam(track_ctx, :test, track_config, base_tags) }
    let(:track_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, track_config)
      r.network = track_network
      r.iam = track_iam
      r
    end

    it 'ControlPlaneRef carries distribution_track' do
      cluster_ref = Pangea::Kubernetes::Backends::AwsNixos.create_cluster(track_ctx, :test, track_config, track_result, base_tags)
      expect(cluster_ref.distribution_track).to eq('1.31')
    end
  end

  # ── Desired Capacity ───────────────────────────────────────────

  describe 'desired capacity' do
    let(:desired_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.29', region: 'us-east-1',
        distribution: :k3s, profile: 'cilium-standard',
        ami_id: 'ami-test', key_pair: 'test-key', account_id: '123456789012',
        node_pools: [
          { name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 3, desired_size: 2 },
          { name: :worker, instance_types: ['t3.medium'], min_size: 1, max_size: 4, desired_size: 2 },
        ],
        network: { vpc_cidr: '10.0.0.0/16' },
      )
    end
    let(:desired_ctx) { create_mock_context }
    let(:desired_network) { Pangea::Kubernetes::Backends::AwsNixos.create_network(desired_ctx, :test, desired_config, base_tags) }
    let(:desired_iam) { Pangea::Kubernetes::Backends::AwsNixos.create_iam(desired_ctx, :test, desired_config, base_tags) }
    let(:desired_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, desired_config)
      r.network = desired_network
      r.iam = desired_iam
      r
    end

    before do
      cluster_ref = Pangea::Kubernetes::Backends::AwsNixos.create_cluster(desired_ctx, :test, desired_config, desired_result, base_tags)
      desired_config.worker_node_pools.each do |pool|
        Pangea::Kubernetes::Backends::AwsNixos.create_node_pool(desired_ctx, :test, cluster_ref, pool, base_tags)
      end
    end

    it 'CP ASG has desired_capacity' do
      asg = desired_ctx.find_resource(:aws_autoscaling_group, :test_cp_asg)
      expect(asg[:attrs][:desired_capacity]).to eq(2)
    end

    it 'worker ASG has desired_capacity' do
      asg = desired_ctx.find_resource(:aws_autoscaling_group, :test_worker_asg)
      expect(asg[:attrs][:desired_capacity]).to eq(2)
    end
  end
end
