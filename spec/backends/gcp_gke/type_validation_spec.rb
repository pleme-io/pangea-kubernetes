# frozen_string_literal: true

# Type validation spec for gcp_gke backend.
#
# Uses TypedSynthesizerContext to run REAL dry-struct type validation
# from pangea-gcp for every resource call. Validates that:
# - All resource calls pass type validation
# - NetworkResult and GcpIamResult typed accessors work
# - Backward-compat hash access works

require 'pangea-gcp'

RSpec.describe 'gcp_gke backend type validation' do
  include SynthesisTestHelpers
  include TypedContextHelpers

  let(:typed_ctx) { create_typed_gcp_context }

  let(:base_tags) { { KubernetesCluster: 'typecheck', Backend: 'gcp', ManagedBy: 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :gcp,
      kubernetes_version: '1.29',
      region: 'us-central1',
      project: 'test-project',
      node_pools: [
        { name: :system, instance_types: ['e2-standard-4'], min_size: 2, max_size: 5, disk_size_gb: 50 }
      ],
      network: {
        vpc_cidr: '10.0.0.0/20',
        pod_cidr: '10.1.0.0/16',
        service_cidr: '10.2.0.0/20',
        private_endpoint: true,
        public_endpoint: false
      }
    )
  end

  describe '.create_network' do
    it 'passes type validation for all network resources' do
      expect {
        Pangea::Kubernetes::Backends::GcpGke.create_network(
          typed_ctx, :typecheck, cluster_config, base_tags
        )
      }.not_to raise_error
    end

    it 'returns a NetworkResult with vpc and subnet' do
      result = Pangea::Kubernetes::Backends::GcpGke.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result).to be_a(Pangea::Contracts::NetworkResult)
      expect(result.vpc).not_to be_nil
      expect(result.subnets.length).to eq(1)
    end

    it 'supports backward-compat hash access' do
      result = Pangea::Kubernetes::Backends::GcpGke.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result[:vpc]).to eq(result.vpc)
      expect(result[:subnet]).not_to be_nil
      expect(result).to have_key(:vpc)
      expect(result).to have_key(:subnet)
    end
  end

  describe '.create_iam' do
    it 'passes type validation for all IAM resources' do
      expect {
        Pangea::Kubernetes::Backends::GcpGke.create_iam(
          typed_ctx, :typecheck, cluster_config, base_tags
        )
      }.not_to raise_error
    end

    it 'returns a GcpIamResult with node_sa' do
      result = Pangea::Kubernetes::Backends::GcpGke.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result).to be_a(Pangea::Contracts::IamResult)
      expect(result[:node_sa]).not_to be_nil
      expect(result.node_sa).not_to be_nil
    end
  end

  describe 'full pipeline' do
    it 'passes type validation for the complete kubernetes_cluster call' do
      synth = create_typed_gcp_context
      synth.extend(Pangea::Kubernetes::Architecture)

      expect {
        synth.kubernetes_cluster(:typecheck_gke, {
          backend: :gcp,
          kubernetes_version: '1.29',
          region: 'us-central1',
          project: 'test-project',
          node_pools: [
            { name: :system, instance_types: ['e2-standard-4'], min_size: 2, max_size: 5, disk_size_gb: 50 },
          ],
          network: {
            vpc_cidr: '10.0.0.0/20',
            pod_cidr: '10.1.0.0/16',
            service_cidr: '10.2.0.0/20',
          },
        })
      }.not_to raise_error
    end

    it 'returns typed ArchitectureResult with correct types' do
      synth = create_typed_gcp_context
      synth.extend(Pangea::Kubernetes::Architecture)

      result = synth.kubernetes_cluster(:typecheck_gke, {
        backend: :gcp,
        kubernetes_version: '1.29',
        region: 'us-central1',
        project: 'test-project',
        node_pools: [
          { name: :system, instance_types: ['e2-standard-4'], min_size: 2, max_size: 5, disk_size_gb: 50 },
        ],
        network: {
          vpc_cidr: '10.0.0.0/20',
          pod_cidr: '10.1.0.0/16',
          service_cidr: '10.2.0.0/20',
        },
      })

      expect(result).to be_a(Pangea::Kubernetes::Architecture::ArchitectureResult)
      expect(result.network).to be_a(Pangea::Contracts::NetworkResult)
      expect(result.iam).to be_a(Pangea::Contracts::IamResult)

      # Verify network typed accessors
      expect(result.network.vpc).not_to be_nil
      expect(result.network[:subnet]).not_to be_nil

      # Verify IAM typed accessors
      expect(result.iam[:node_sa]).not_to be_nil
    end
  end
end
