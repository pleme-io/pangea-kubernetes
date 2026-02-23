# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Backends::AwsEks do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'production', Backend: 'aws', ManagedBy: 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :aws,
      kubernetes_version: '1.29',
      region: 'us-east-1',
      node_pools: [
        { name: :system, instance_types: ['t3.large'], min_size: 2, max_size: 5 }
      ],
      network: {
        vpc_cidr: '10.0.0.0/16',
        private_endpoint: true,
        public_endpoint: false
      }
    )
  end

  describe '.backend_name' do
    it 'returns :aws' do
      expect(described_class.backend_name).to eq(:aws)
    end
  end

  describe '.managed_kubernetes?' do
    it 'returns true' do
      expect(described_class.managed_kubernetes?).to be true
    end
  end

  describe '.create_network' do
    it 'creates VPC and 2 subnets' do
      result = described_class.create_network(ctx, :production, cluster_config, base_tags)

      expect(result).to have_key(:vpc)
      expect(result[:vpc].type).to eq('aws_vpc')

      expect(result).to have_key(:subnet_a)
      expect(result).to have_key(:subnet_b)
      expect(result[:subnet_a].type).to eq('aws_subnet')
    end

    it 'creates subnets in different AZs' do
      described_class.create_network(ctx, :production, cluster_config, base_tags)

      subnet_a = ctx.find_resource(:aws_subnet, :production_subnet_a)
      subnet_b = ctx.find_resource(:aws_subnet, :production_subnet_b)

      expect(subnet_a[:attrs][:availability_zone]).to eq('us-east-1a')
      expect(subnet_b[:attrs][:availability_zone]).to eq('us-east-1b')
    end

    it 'uses configured VPC CIDR' do
      described_class.create_network(ctx, :production, cluster_config, base_tags)
      vpc = ctx.find_resource(:aws_vpc, :production_vpc)
      expect(vpc[:attrs][:cidr_block]).to eq('10.0.0.0/16')
    end
  end

  describe '.create_iam' do
    it 'creates cluster role when no role_arn provided' do
      result = described_class.create_iam(ctx, :production, cluster_config, base_tags)

      expect(result).to have_key(:cluster_role)
      expect(result[:cluster_role].type).to eq('aws_iam_role')
      expect(result).to have_key(:cluster_policy_attachment)
    end

    it 'creates node role with required policies' do
      result = described_class.create_iam(ctx, :production, cluster_config, base_tags)

      expect(result).to have_key(:node_role)
      expect(result[:node_role].type).to eq('aws_iam_role')

      # Should attach 3 node policies
      policy_attachments = ctx.created_resources.select { |r| r[:type] == 'aws_iam_role_policy_attachment' }
      # 1 cluster + 3 node = 4 total
      expect(policy_attachments.size).to eq(4)
    end

    it 'skips cluster role when role_arn provided' do
      config_with_role = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws,
        region: 'us-east-1',
        role_arn: 'arn:aws:iam::123:role/existing',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }]
      )

      result = described_class.create_iam(ctx, :production, config_with_role, base_tags)
      expect(result).not_to have_key(:cluster_role)
      expect(result).to have_key(:node_role)
    end
  end

  describe '.create_cluster' do
    let(:network_result) do
      described_class.create_network(ctx, :production, cluster_config, base_tags)
    end

    let(:iam_result) do
      described_class.create_iam(ctx, :production, cluster_config, base_tags)
    end

    let(:arch_result) do
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:production, cluster_config)
      result.network = network_result
      result.iam = iam_result
      result
    end

    it 'creates an EKS cluster' do
      cluster = described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      expect(cluster.type).to eq('aws_eks_cluster')
      eks = ctx.find_resource(:aws_eks_cluster, :production_cluster)
      expect(eks[:attrs][:version]).to eq('1.29')
    end

    it 'configures VPC with subnet IDs from network' do
      cluster = described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      eks = ctx.find_resource(:aws_eks_cluster, :production_cluster)
      expect(eks[:attrs][:vpc_config][:subnet_ids]).to be_an(Array)
      expect(eks[:attrs][:vpc_config][:subnet_ids].size).to eq(2)
    end

    it 'sets endpoint access from config' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      eks = ctx.find_resource(:aws_eks_cluster, :production_cluster)
      expect(eks[:attrs][:vpc_config][:endpoint_private_access]).to be true
      expect(eks[:attrs][:vpc_config][:endpoint_public_access]).to be false
    end

    it 'enables encryption at rest by default' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      eks = ctx.find_resource(:aws_eks_cluster, :production_cluster)
      expect(eks[:attrs][:encryption_config]).to be_an(Array)
      expect(eks[:attrs][:encryption_config].first[:resources]).to eq(['secrets'])
    end
  end

  describe '.create_node_pool' do
    let(:cluster_ref) { MockResourceRef.new('aws_eks_cluster', :production_cluster, { name: 'production-cluster' }) }
    let(:pool_config) do
      Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :workers,
        instance_types: ['c5.xlarge'],
        min_size: 3,
        max_size: 20,
        disk_size_gb: 100
      )
    end

    it 'creates an EKS node group' do
      ref = described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      expect(ref.type).to eq('aws_eks_node_group')
      node_group = ctx.find_resource(:aws_eks_node_group, :production_workers)
      expect(node_group).not_to be_nil
    end

    it 'sets scaling configuration' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      node_group = ctx.find_resource(:aws_eks_node_group, :production_workers)
      expect(node_group[:attrs][:scaling_config]).to eq({
        desired_size: 3,
        min_size: 3,
        max_size: 20
      })
    end

    it 'sets instance types and disk size' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      node_group = ctx.find_resource(:aws_eks_node_group, :production_workers)
      expect(node_group[:attrs][:instance_types]).to eq(['c5.xlarge'])
      expect(node_group[:attrs][:disk_size]).to eq(100)
    end

    it 'includes labels when set' do
      labeled_pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :gpu,
        instance_types: ['p3.2xlarge'],
        labels: { 'gpu' => 'true', 'workload' => 'ml' }
      )

      described_class.create_node_pool(ctx, :production, cluster_ref, labeled_pool, base_tags)
      node_group = ctx.find_resource(:aws_eks_node_group, :production_gpu)
      expect(node_group[:attrs][:labels]).to eq({ 'gpu' => 'true', 'workload' => 'ml' })
    end

    it 'includes taints when set' do
      tainted_pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :dedicated,
        instance_types: ['c5.xlarge'],
        taints: [{ key: 'dedicated', value: 'gpu', effect: 'NoSchedule' }]
      )

      described_class.create_node_pool(ctx, :production, cluster_ref, tainted_pool, base_tags)
      node_group = ctx.find_resource(:aws_eks_node_group, :production_dedicated)
      expect(node_group[:attrs][:taint]).to be_an(Array)
      expect(node_group[:attrs][:taint].first[:key]).to eq('dedicated')
    end
  end
end
