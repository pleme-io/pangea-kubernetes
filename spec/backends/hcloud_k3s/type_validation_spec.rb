# frozen_string_literal: true

# Type validation spec for hcloud_k3s backend.
#
# Uses TypedSynthesizerContext to run REAL dry-struct type validation
# from pangea-hcloud for every resource call. Validates that:
# - All resource calls pass type validation
# - HcloudNetworkResult provides network and subnet accessors
# - Empty IamResult is returned (NixOS uses no cloud IAM)
# - Full pipeline works with NixOS cloud-init

require 'pangea-hcloud'

RSpec.describe 'hcloud_k3s backend type validation' do
  include SynthesisTestHelpers
  include TypedContextHelpers

  let(:typed_ctx) { create_typed_hcloud_context }

  let(:base_tags) { { KubernetesCluster: 'typecheck', Backend: 'hcloud', ManagedBy: 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :hcloud,
      kubernetes_version: '1.29',
      region: 'eu-central',
      distribution: :k3s,
      profile: 'cilium-standard',
      node_pools: [
        { name: :system, instance_types: ['cpx21'], min_size: 1, max_size: 1, disk_size_gb: 40 }
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
        Pangea::Kubernetes::Backends::HcloudK3s.create_network(
          typed_ctx, :typecheck, cluster_config, base_tags
        )
      }.not_to raise_error
    end

    it 'returns an HcloudNetworkResult with network and subnet' do
      result = Pangea::Kubernetes::Backends::HcloudK3s.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result).to be_a(Pangea::Kubernetes::Architecture::HcloudNetworkResult)
      expect(result.network).not_to be_nil
      expect(result.vpc).not_to be_nil
      expect(result.vpc).to eq(result.network)
      expect(result.subnets.length).to eq(1)
    end

    it 'supports backward-compat hash access for Hcloud-specific fields' do
      result = Pangea::Kubernetes::Backends::HcloudK3s.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result[:network]).to eq(result.network)
      expect(result[:subnet]).not_to be_nil
      expect(result).to have_key(:network)
      expect(result).to have_key(:subnet)
    end
  end

  describe '.create_iam' do
    it 'returns an empty IamResult (NixOS uses no cloud IAM)' do
      result = Pangea::Kubernetes::Backends::HcloudK3s.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result).to be_a(Pangea::Contracts::IamResult)
      expect(result.to_h).to eq({})
    end
  end

  describe 'typed contract' do
    it 'HcloudNetworkResult provides typed accessors for all Hcloud fields' do
      network = Pangea::Kubernetes::Backends::HcloudK3s.create_network(
        typed_ctx, :contract, cluster_config, base_tags
      )
      expect(network).to be_a(Pangea::Kubernetes::Architecture::HcloudNetworkResult)
      expect(network.network).not_to be_nil
      expect(network.vpc).to eq(network.network)
      expect(network[:subnet]).not_to be_nil
      expect(network[:network]).to eq(network.network)
    end

    it 'empty IamResult for NixOS (no cloud IAM)' do
      iam = Pangea::Kubernetes::Backends::HcloudK3s.create_iam(
        typed_ctx, :contract, cluster_config, base_tags
      )
      expect(iam).to be_a(Pangea::Contracts::IamResult)
      expect(iam.to_h).to eq({})
    end
  end
end
