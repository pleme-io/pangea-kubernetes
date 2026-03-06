# frozen_string_literal: true

RSpec.describe 'AWS EKS cluster edge cases' do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'production', Backend: 'aws', ManagedBy: 'Pangea' } }

  describe 'subnet ID resolution' do
    it 'uses explicit subnet_ids from network config when provided' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws,
        region: 'us-east-1',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        network: {
          subnet_ids: ['subnet-aaa', 'subnet-bbb'],
          vpc_cidr: '10.0.0.0/16'
        }
      )
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:prod, config)
      result.network = Pangea::Kubernetes::Backends::AwsEks.create_network(ctx, :prod, config, base_tags)
      result.iam = Pangea::Kubernetes::Backends::AwsEks.create_iam(ctx, :prod, config, base_tags)

      Pangea::Kubernetes::Backends::AwsEks.create_cluster(ctx, :prod, config, result, base_tags)
      eks = ctx.find_resource(:aws_eks_cluster, :prod_cluster)
      expect(eks[:attrs][:vpc_config][:subnet_ids]).to eq(['subnet-aaa', 'subnet-bbb'])
    end

    it 'falls back to empty when no network and no subnet_ids' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws,
        region: 'us-east-1',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }]
      )
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:prod, config)
      result.iam = Pangea::Kubernetes::Backends::AwsEks.create_iam(ctx, :prod, config, base_tags)

      Pangea::Kubernetes::Backends::AwsEks.create_cluster(ctx, :prod, config, result, base_tags)
      eks = ctx.find_resource(:aws_eks_cluster, :prod_cluster)
      expect(eks[:attrs][:vpc_config][:subnet_ids]).to eq([])
    end
  end

  describe 'logging configuration' do
    it 'includes enabled_cluster_log_types when logging specified' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws,
        region: 'us-east-1',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        logging: ['api', 'audit', 'authenticator']
      )
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:prod, config)
      result.iam = Pangea::Kubernetes::Backends::AwsEks.create_iam(ctx, :prod, config, base_tags)

      Pangea::Kubernetes::Backends::AwsEks.create_cluster(ctx, :prod, config, result, base_tags)
      eks = ctx.find_resource(:aws_eks_cluster, :prod_cluster)
      expect(eks[:attrs][:enabled_cluster_log_types]).to eq(['api', 'audit', 'authenticator'])
    end
  end

  describe 'encryption disabled' do
    it 'skips encryption_config when encryption_at_rest is false' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws,
        region: 'us-east-1',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        encryption_at_rest: false
      )
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:prod, config)
      result.iam = Pangea::Kubernetes::Backends::AwsEks.create_iam(ctx, :prod, config, base_tags)

      Pangea::Kubernetes::Backends::AwsEks.create_cluster(ctx, :prod, config, result, base_tags)
      eks = ctx.find_resource(:aws_eks_cluster, :prod_cluster)
      expect(eks[:attrs]).not_to have_key(:encryption_config)
    end
  end
end
