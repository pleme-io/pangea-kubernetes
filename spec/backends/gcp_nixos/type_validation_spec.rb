# frozen_string_literal: true

# Type validation spec for gcp_nixos backend.
#
# Uses TypedSynthesizerContext to run REAL dry-struct type validation
# from pangea-gcp for every resource call. Validates that:
# - All resource calls pass type validation
# - GcpNetworkResult provides firewall_internal/external accessors
# - GcpIamResult provides node_sa accessor
# - Full pipeline works with NixOS cloud-init

require 'pangea-gcp'

RSpec.describe 'gcp_nixos backend type validation' do
  include SynthesisTestHelpers
  include TypedContextHelpers

  let(:typed_ctx) { create_typed_gcp_context }

  let(:base_tags) { { KubernetesCluster: 'typecheck', Backend: 'gcp_nixos', ManagedBy: 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :gcp_nixos,
      kubernetes_version: '1.29',
      region: 'us-central1',
      project: 'test-project',
      distribution: :k3s,
      profile: 'cilium-standard',
      node_pools: [
        { name: :system, instance_types: ['e2-standard-4'], min_size: 1, max_size: 1, disk_size_gb: 50 }
      ],
      network: {
        vpc_cidr: '10.0.0.0/20'
      }
    )
  end

  describe '.create_network' do
    it 'passes type validation for all network resources' do
      expect {
        Pangea::Kubernetes::Backends::GcpNixos.create_network(
          typed_ctx, :typecheck, cluster_config, base_tags
        )
      }.not_to raise_error
    end

    it 'returns a GcpNetworkResult with vpc, subnet, and firewalls' do
      result = Pangea::Kubernetes::Backends::GcpNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result).to be_a(Pangea::Kubernetes::Architecture::GcpNetworkResult)
      expect(result.vpc).not_to be_nil
      expect(result.subnets.length).to eq(1)
      expect(result.firewall_internal).not_to be_nil
      expect(result.firewall_external).not_to be_nil
    end

    it 'supports backward-compat hash access for GCP-specific fields' do
      result = Pangea::Kubernetes::Backends::GcpNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result[:vpc]).to eq(result.vpc)
      expect(result[:subnet]).not_to be_nil
      expect(result[:firewall_internal]).to eq(result.firewall_internal)
      expect(result[:firewall_external]).to eq(result.firewall_external)
      expect(result).to have_key(:firewall_internal)
    end
  end

  describe '.create_iam' do
    it 'passes type validation for all IAM resources' do
      expect {
        Pangea::Kubernetes::Backends::GcpNixos.create_iam(
          typed_ctx, :typecheck, cluster_config, base_tags
        )
      }.not_to raise_error
    end

    it 'returns a GcpIamResult with node_sa' do
      result = Pangea::Kubernetes::Backends::GcpNixos.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result).to be_a(Pangea::Contracts::IamResult)
      expect(result[:node_sa]).not_to be_nil
      expect(result.node_sa).not_to be_nil
    end
  end

  describe 'typed contract' do
    it 'GcpNetworkResult provides typed accessors for all GCP fields' do
      network = Pangea::Kubernetes::Backends::GcpNixos.create_network(
        typed_ctx, :contract, cluster_config, base_tags
      )
      expect(network).to be_a(Pangea::Kubernetes::Architecture::GcpNetworkResult)
      expect(network.vpc).not_to be_nil
      expect(network[:subnet]).not_to be_nil
      expect(network.firewall_internal).not_to be_nil
      expect(network.firewall_external).not_to be_nil
      expect(network[:firewall_internal]).to eq(network.firewall_internal)
    end

    it 'GcpIamResult provides node_sa accessor' do
      iam = Pangea::Kubernetes::Backends::GcpNixos.create_iam(
        typed_ctx, :contract, cluster_config, base_tags
      )
      expect(iam).to be_a(Pangea::Contracts::IamResult)
      expect(iam.node_sa).not_to be_nil
      expect(iam[:node_sa]).to eq(iam.node_sa)
    end
  end
end
