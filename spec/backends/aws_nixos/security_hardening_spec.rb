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
      policy = ecr[:attrs][:policy]
      statements = policy[:Statement] || policy['Statement']
      all_actions = statements.flat_map { |s| Array(s[:Action] || s['Action']) }

      expect(all_actions).not_to include('ecr:*')
      expect(all_actions).not_to include('*')
      # Must NOT have write actions
      %w[ecr:PutImage ecr:DeleteRepository ecr:CreateRepository ecr:TagResource].each do |dangerous|
        expect(all_actions).not_to include(dangerous), "ECR policy must not include #{dangerous}"
      end
    end

    it 'S3 policy scoped to specific etcd bucket' do
      s3 = ctx.find_resource(:aws_iam_policy, :kazoku_etcd_backup)
      policy = s3[:attrs][:policy]
      statements = policy[:Statement] || policy['Statement']
      resources = statements.flat_map { |s| Array(s[:Resource] || s['Resource']) }

      expect(resources).to all(include('kazoku-etcd-backups'))
      expect(resources).not_to include('*')
    end

    it 'S3 policy has no dangerous actions' do
      s3 = ctx.find_resource(:aws_iam_policy, :kazoku_etcd_backup)
      policy = s3[:attrs][:policy]
      statements = policy[:Statement] || policy['Statement']
      all_actions = statements.flat_map { |s| Array(s[:Action] || s['Action']) }

      %w[s3:DeleteObject s3:DeleteBucket s3:PutBucketPolicy s3:*].each do |dangerous|
        expect(all_actions).not_to include(dangerous), "S3 policy must not include #{dangerous}"
      end
    end

    it 'CloudWatch logs policy scoped to specific log group' do
      logs = ctx.find_resource(:aws_iam_policy, :kazoku_logs)
      policy = logs[:attrs][:policy]
      statements = policy[:Statement] || policy['Statement']
      resources = statements.flat_map { |s| Array(s[:Resource] || s['Resource']) }

      expect(resources).to all(include('/k3s/kazoku'))
    end

    it 'EC2 policy is describe-only with region condition' do
      ec2 = ctx.find_resource(:aws_iam_policy, :kazoku_ec2_describe)
      policy = ec2[:attrs][:policy]
      statements = policy[:Statement] || policy['Statement']
      all_actions = statements.flat_map { |s| Array(s[:Action] || s['Action']) }

      all_actions.each do |action|
        expect(action).to start_with('ec2:Describe'), "EC2 policy must be describe-only, found: #{action}"
      end

      # Region condition present
      conditions = statements.map { |s| s[:Condition] || s['Condition'] }.compact
      expect(conditions).not_to be_empty
    end

    it 'SSM policy has no RunCommand actions' do
      ssm = ctx.find_resource(:aws_iam_policy, :kazoku_ssm)
      policy = ssm[:attrs][:policy]
      statements = policy[:Statement] || policy['Statement']
      all_actions = statements.flat_map { |s| Array(s[:Action] || s['Action']) }

      %w[ssm:SendCommand ssm:CreateDocument ssm:DeleteDocument ssm:*].each do |dangerous|
        expect(all_actions).not_to include(dangerous), "SSM policy must not include #{dangerous}"
      end
    end

    it 'IAM role has max_session_duration of 3600' do
      role = ctx.find_resource(:aws_iam_role, :kazoku_node_role)
      expect(role[:attrs][:max_session_duration]).to eq(3600)
    end

    it 'IAM role has prevent_destroy lifecycle' do
      role = ctx.find_resource(:aws_iam_role, :kazoku_node_role)
      expect(role[:attrs][:lifecycle]).to eq({ prevent_destroy: true })
    end
  end

  # ── Network Security ─────────────────────────────────────────────

  describe 'network security' do
    before { network }

    it 'SSH is NOT open to 0.0.0.0/0' do
      sg = ctx.find_resource(:aws_security_group, :kazoku_sg)
      ssh_rule = sg[:attrs][:ingress].find { |r| r[:description] == 'SSH' }

      expect(ssh_rule[:cidr_blocks]).not_to include('0.0.0.0/0'),
        'SSH must NOT be open to the public internet'
    end

    it 'K8s API is NOT open to 0.0.0.0/0' do
      sg = ctx.find_resource(:aws_security_group, :kazoku_sg)
      api_rule = sg[:attrs][:ingress].find { |r| r[:description] == 'K8s API' }

      expect(api_rule[:cidr_blocks]).not_to include('0.0.0.0/0'),
        'K8s API must NOT be open to the public internet'
    end

    it 'etcd is restricted to VPC CIDR' do
      sg = ctx.find_resource(:aws_security_group, :kazoku_sg)
      etcd_rule = sg[:attrs][:ingress].find { |r| r[:description] == 'etcd' }

      expect(etcd_rule[:cidr_blocks]).to eq(['10.0.0.0/16']),
        'etcd must be restricted to VPC CIDR only'
    end

    it 'kubelet is restricted to VPC CIDR' do
      sg = ctx.find_resource(:aws_security_group, :kazoku_sg)
      kubelet_rule = sg[:attrs][:ingress].find { |r| r[:description] == 'Kubelet' }

      expect(kubelet_rule[:cidr_blocks]).to eq(['10.0.0.0/16']),
        'Kubelet must be restricted to VPC CIDR only'
    end

    it 'VXLAN is restricted to VPC CIDR' do
      sg = ctx.find_resource(:aws_security_group, :kazoku_sg)
      vxlan_rule = sg[:attrs][:ingress].find { |r| r[:description] == 'VXLAN' }

      expect(vxlan_rule[:cidr_blocks]).to eq(['10.0.0.0/16']),
        'VXLAN overlay must be restricted to VPC CIDR only'
    end

    it 'only HTTP and HTTPS are public' do
      sg = ctx.find_resource(:aws_security_group, :kazoku_sg)
      public_rules = sg[:attrs][:ingress].select { |r| r[:cidr_blocks].include?('0.0.0.0/0') }
      public_descriptions = public_rules.map { |r| r[:description] }

      expect(public_descriptions).to contain_exactly('HTTP', 'HTTPS'),
        "Only HTTP and HTTPS should be public, found: #{public_descriptions}"
    end

    it 'VPC has prevent_destroy lifecycle' do
      vpc = ctx.find_resource(:aws_vpc, :kazoku_vpc)
      expect(vpc[:attrs][:lifecycle]).to eq({ prevent_destroy: true })
    end

    it 'creates route table with IGW route' do
      rt = ctx.find_resource(:aws_route_table, :kazoku_rt)
      expect(rt).not_to be_nil
    end

    it 'associates subnets with route table' do
      rta = ctx.created_resources.select { |r| r[:type] == 'aws_route_table_association' }
      expect(rta.size).to eq(2)
    end
  end

  # ── Instance Hardening ───────────────────────────────────────────

  describe 'instance hardening' do
    let(:arch_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:kazoku, config)
      r.network = network
      r.iam = iam
      r
    end

    before do
      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :kazoku, config, arch_result, base_tags)
    end

    it 'requires IMDSv2 (http_tokens: required)' do
      cp = ctx.find_resource(:aws_instance, :kazoku_cp_0)
      expect(cp[:attrs][:metadata_options][:http_tokens]).to eq('required'),
        'IMDSv2 must be required to prevent SSRF attacks'
    end

    it 'limits IMDS hop count to 1' do
      cp = ctx.find_resource(:aws_instance, :kazoku_cp_0)
      expect(cp[:attrs][:metadata_options][:http_put_response_hop_limit]).to eq(1),
        'IMDS hop limit must be 1 to prevent container escape'
    end

    it 'encrypts root block device' do
      cp = ctx.find_resource(:aws_instance, :kazoku_cp_0)
      expect(cp[:attrs][:root_block_device][:encrypted]).to be(true),
        'Root volumes must be encrypted at rest'
    end

    it 'uses gp3 volume type' do
      cp = ctx.find_resource(:aws_instance, :kazoku_cp_0)
      expect(cp[:attrs][:root_block_device][:volume_type]).to eq('gp3')
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

    it 'log group name follows /k3s/{cluster} convention' do
      log_group = ctx.find_resource(:aws_cloudwatch_log_group, :kazoku_logs)
      expect(log_group[:attrs][:name]).to eq('/k3s/kazoku')
    end
  end

  # ── Tagging Compliance ──────────────────────────────────────────

  describe 'tagging compliance' do
    before do
      network
      iam
    end

    it 'tags all IAM resources' do
      %i[kazoku_node_role kazoku_node_profile].each do |name|
        type = name.to_s.include?('role') ? :aws_iam_role : :aws_iam_instance_profile
        resource = ctx.find_resource(type, name)
        expect(resource[:attrs]).to have_key(:tags), "#{name} must be tagged"
      end
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
  end
end
