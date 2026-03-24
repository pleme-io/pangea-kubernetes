# frozen_string_literal: true

# Type validation spec for azure_aks backend.
#
# Uses TypedSynthesizerContext to run REAL dry-struct type validation
# from pangea-azure for every resource call. Validates that:
# - All resource calls pass type validation
# - AzureNetworkResult provides resource_group, vnet, subnet accessors
# - Empty IamResult is returned (AKS uses managed identity)

require 'pangea-azure'

RSpec.describe 'azure_aks backend type validation' do
  include SynthesisTestHelpers
  include TypedContextHelpers

  let(:typed_ctx) { create_typed_azure_context }

  let(:base_tags) { { 'KubernetesCluster' => 'typecheck', 'Backend' => 'azure', 'ManagedBy' => 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :azure,
      kubernetes_version: '1.29',
      region: 'eastus',
      node_pools: [
        { name: :system, instance_types: ['Standard_D4s_v3'], min_size: 2, max_size: 5, disk_size_gb: 50 }
      ],
      network: {
        vpc_cidr: '10.0.0.0/16',
        pod_cidr: '10.0.1.0/24'
      }
    )
  end

  describe '.create_network' do
    it 'passes type validation for all network resources' do
      expect {
        Pangea::Kubernetes::Backends::AzureAks.create_network(
          typed_ctx, :typecheck, cluster_config, base_tags
        )
      }.not_to raise_error
    end

    it 'returns an AzureNetworkResult with resource_group, vnet, and subnet' do
      result = Pangea::Kubernetes::Backends::AzureAks.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result).to be_a(Pangea::Kubernetes::Architecture::AzureNetworkResult)
      expect(result.resource_group).not_to be_nil
      expect(result.vnet).not_to be_nil
      expect(result.vpc).not_to be_nil
      expect(result.vpc).to eq(result.vnet)
      expect(result.subnets.length).to eq(1)
    end

    it 'supports backward-compat hash access for Azure-specific fields' do
      result = Pangea::Kubernetes::Backends::AzureAks.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result[:resource_group]).to eq(result.resource_group)
      expect(result[:vnet]).to eq(result.vnet)
      expect(result[:subnet]).not_to be_nil
      expect(result).to have_key(:resource_group)
      expect(result).to have_key(:vnet)
      expect(result).to have_key(:subnet)
    end
  end

  describe '.create_iam' do
    it 'returns an empty IamResult (AKS uses managed identity)' do
      result = Pangea::Kubernetes::Backends::AzureAks.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result).to be_a(Pangea::Contracts::IamResult)
      expect(result.to_h).to eq({})
    end
  end

  describe 'typed contract' do
    it 'AzureNetworkResult provides typed accessors for all Azure fields' do
      network = Pangea::Kubernetes::Backends::AzureAks.create_network(
        typed_ctx, :contract, cluster_config, base_tags
      )
      expect(network).to be_a(Pangea::Kubernetes::Architecture::AzureNetworkResult)
      expect(network.resource_group).not_to be_nil
      expect(network.vnet).not_to be_nil
      expect(network.vpc).to eq(network.vnet)
      expect(network.subnets.length).to eq(1)
      expect(network[:resource_group]).to eq(network.resource_group)
      expect(network[:vnet]).to eq(network.vnet)
    end

    it 'empty IamResult for AKS managed identity' do
      iam = Pangea::Kubernetes::Backends::AzureAks.create_iam(
        typed_ctx, :contract, cluster_config, base_tags
      )
      expect(iam).to be_a(Pangea::Contracts::IamResult)
      expect(iam.to_h).to eq({})
    end
  end
end
