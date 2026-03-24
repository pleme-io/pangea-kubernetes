# frozen_string_literal: true

# Type validation spec for aws_eks backend.
#
# Uses TypedSynthesizerContext to run REAL dry-struct type validation
# from pangea-aws for every resource call. Validates that:
# - assume_role_policy is passed as Hash (not JSON String)
# - All resource calls pass type validation
# - NetworkResult and IamResult typed accessors work

require 'pangea-aws'

RSpec.describe 'aws_eks backend type validation' do
  include SynthesisTestHelpers
  include TypedContextHelpers

  let(:typed_ctx) { create_typed_aws_context }

  it_behaves_like 'typed backend contract',
    Pangea::Kubernetes::Backends::AwsEks,
    :create_typed_aws_context

  let(:base_tags) { { KubernetesCluster: 'typecheck', Backend: 'aws', ManagedBy: 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :aws,
      kubernetes_version: '1.29',
      region: 'us-east-1',
      node_pools: [
        { name: :system, instance_types: ['t3.large'], min_size: 2, max_size: 5, disk_size_gb: 50 }
      ],
      network: {
        vpc_cidr: '10.0.0.0/16',
        private_endpoint: true,
        public_endpoint: false
      }
    )
  end

  describe '.create_network' do
    it 'passes type validation for all network resources' do
      expect {
        Pangea::Kubernetes::Backends::AwsEks.create_network(
          typed_ctx, :typecheck, cluster_config, base_tags
        )
      }.not_to raise_error
    end

    it 'returns a NetworkResult with vpc and subnets' do
      result = Pangea::Kubernetes::Backends::AwsEks.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result).to be_a(Pangea::Contracts::NetworkResult)
      expect(result.vpc).not_to be_nil
      expect(result.subnets.length).to eq(2)
      expect(result.subnet_ids.length).to eq(2)
    end

    it 'supports backward-compat hash access' do
      result = Pangea::Kubernetes::Backends::AwsEks.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result[:vpc]).to eq(result.vpc)
      expect(result[:subnet_a]).to eq(result.subnets.first)
      expect(result[:subnet_b]).to eq(result.subnets.last)
      expect(result).to have_key(:vpc)
      expect(result).to have_key(:subnet_a)
    end
  end

  describe '.create_iam' do
    it 'passes type validation for all IAM resources' do
      expect {
        Pangea::Kubernetes::Backends::AwsEks.create_iam(
          typed_ctx, :typecheck, cluster_config, base_tags
        )
      }.not_to raise_error
    end

    it 'returns an AwsEksIamResult with cluster_role and node_role' do
      result = Pangea::Kubernetes::Backends::AwsEks.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result).to be_a(Pangea::Contracts::IamResult)
      expect(result[:cluster_role]).not_to be_nil
      expect(result[:node_role]).not_to be_nil
      expect(result[:cluster_policy_attachment]).not_to be_nil
    end

    it 'passes assume_role_policy as Hash (not JSON String)' do
      iam = Pangea::Kubernetes::Backends::AwsEks.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(iam.cluster_role).not_to be_nil
      expect(iam.node_role).not_to be_nil
    end
  end

  describe '.create_cluster' do
    let(:network) do
      Pangea::Kubernetes::Backends::AwsEks.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
    end
    let(:iam) do
      Pangea::Kubernetes::Backends::AwsEks.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
    end
    let(:arch_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:typecheck, cluster_config)
      r.network = network
      r.iam = iam
      r
    end

    it 'passes type validation for EKS cluster resource' do
      expect {
        Pangea::Kubernetes::Backends::AwsEks.create_cluster(
          typed_ctx, :typecheck, cluster_config, arch_result, base_tags
        )
      }.not_to raise_error
    end
  end

  describe 'typed contract' do
    it 'NetworkResult provides subnets array and backward-compat hash access' do
      network = Pangea::Kubernetes::Backends::AwsEks.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(network).to be_a(Pangea::Contracts::NetworkResult)
      expect(network.subnets.length).to eq(2)
      expect(network.subnet_ids.length).to eq(2)
      expect(network[:vpc]).to eq(network.vpc)
      expect(network[:subnet_a]).to eq(network.subnets.first)
    end

    it 'IamResult provides named accessors for EKS roles' do
      iam = Pangea::Kubernetes::Backends::AwsEks.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(iam).to be_a(Pangea::Contracts::IamResult)
      expect(iam.cluster_role).not_to be_nil
      expect(iam.node_role).not_to be_nil
      expect(iam[:cluster_role]).to eq(iam.cluster_role)
    end
  end
end
