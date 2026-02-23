# frozen_string_literal: true

RSpec.describe 'AWS EKS Node Pool Synthesis' do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'prod', Backend: 'aws', ManagedBy: 'Pangea' } }
  let(:cluster_ref) { MockResourceRef.new('aws_eks_cluster', :prod_cluster, { name: 'prod-cluster' }) }

  it 'creates multiple node pools independently' do
    pools = [
      { name: :system, instance_types: ['t3.large'], min_size: 2, max_size: 5 },
      { name: :workers, instance_types: ['c5.xlarge'], min_size: 3, max_size: 20 },
      { name: :gpu, instance_types: ['p3.2xlarge'], min_size: 0, max_size: 4 }
    ]

    pools.each do |pool_attrs|
      pool_config = Pangea::Kubernetes::Types::NodePoolConfig.new(pool_attrs)
      Pangea::Kubernetes::Backends::AwsEks.create_node_pool(ctx, :prod, cluster_ref, pool_config, base_tags)
    end

    expect(ctx.count_resources('aws_eks_node_group')).to eq(3)
    expect(ctx.find_resource(:aws_eks_node_group, :prod_system)).not_to be_nil
    expect(ctx.find_resource(:aws_eks_node_group, :prod_workers)).not_to be_nil
    expect(ctx.find_resource(:aws_eks_node_group, :prod_gpu)).not_to be_nil
  end

  it 'uses effective_desired_size (falls back to min_size)' do
    pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
      name: :workers, instance_types: ['c5.xlarge'], min_size: 5, max_size: 20
    )
    Pangea::Kubernetes::Backends::AwsEks.create_node_pool(ctx, :prod, cluster_ref, pool, base_tags)

    node_group = ctx.find_resource(:aws_eks_node_group, :prod_workers)
    expect(node_group[:attrs][:scaling_config][:desired_size]).to eq(5)
  end

  it 'respects explicit desired_size' do
    pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
      name: :workers, instance_types: ['c5.xlarge'], min_size: 3, max_size: 20, desired_size: 10
    )
    Pangea::Kubernetes::Backends::AwsEks.create_node_pool(ctx, :prod, cluster_ref, pool, base_tags)

    node_group = ctx.find_resource(:aws_eks_node_group, :prod_workers)
    expect(node_group[:attrs][:scaling_config][:desired_size]).to eq(10)
  end
end
