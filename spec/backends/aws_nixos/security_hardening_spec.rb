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
      node_pools: [
        { name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 },
        { name: :worker, instance_types: ['t3.medium'], min_size: 1, max_size: 4 },
      ],
      network: { vpc_cidr: '10.0.0.0/16' },
      tags: {
        account_id: '123456789012',
        etcd_backup_bucket: 'kazoku-etcd-backups',
        ssh_cidr: '10.0.0.0/8',
        api_cidr: '10.0.0.0/8',
      },
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
        tags: { account_id: '123', ssh_cidr: '0.0.0.0/0' },
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
        tags: { account_id: '123', api_cidr: '0.0.0.0/0' },
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

    it 'creates route table with separate default route' do
      rt = ctx.find_resource(:aws_route_table, :kazoku_rt)
      expect(rt).not_to be_nil
      route = ctx.find_resource(:aws_route, :kazoku_default_route)
      expect(route).not_to be_nil
      expect(route[:attrs][:destination_cidr_block]).to eq('0.0.0.0/0')
    end

    it 'associates subnets with route table' do
      rta = ctx.created_resources.select { |r| r[:type] == 'aws_route_table_association' }
      expect(rta.size).to eq(2)
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
      expect(versioning[:attrs][:versioning_configuration]).to eq([{ status: 'Enabled' }])
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
      expect(lt[:attrs][:metadata_options].first[:http_tokens]).to eq('required')
    end

    it 'limits IMDS hop count to 1 on launch template' do
      lt = ctx.find_resource(:aws_launch_template, :kazoku_cp_lt)
      expect(lt[:attrs][:metadata_options].first[:http_put_response_hop_limit]).to eq(1)
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
end
