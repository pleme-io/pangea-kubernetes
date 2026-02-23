# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Backends::GcpGke do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'production', Backend: 'gcp', ManagedBy: 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :gcp,
      kubernetes_version: '1.29',
      region: 'us-central1',
      project: 'my-project',
      node_pools: [
        { name: :system, instance_types: ['e2-standard-4'], min_size: 2, max_size: 5 }
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

  describe '.backend_name' do
    it 'returns :gcp' do
      expect(described_class.backend_name).to eq(:gcp)
    end
  end

  describe '.managed_kubernetes?' do
    it 'returns true' do
      expect(described_class.managed_kubernetes?).to be true
    end
  end

  describe '.create_network' do
    it 'creates VPC network and subnet' do
      result = described_class.create_network(ctx, :production, cluster_config, base_tags)

      expect(result).to have_key(:vpc)
      expect(result[:vpc].type).to eq('google_compute_network')
      expect(result).to have_key(:subnet)
      expect(result[:subnet].type).to eq('google_compute_subnetwork')
    end

    it 'configures secondary IP ranges for pods and services' do
      described_class.create_network(ctx, :production, cluster_config, base_tags)

      subnet = ctx.find_resource(:google_compute_subnetwork, :production_subnet)
      ranges = subnet[:attrs][:secondary_ip_range]
      expect(ranges.size).to eq(2)
      expect(ranges.first[:range_name]).to eq('production-pods')
      expect(ranges.last[:range_name]).to eq('production-services')
    end
  end

  describe '.create_iam' do
    it 'creates service account for nodes' do
      result = described_class.create_iam(ctx, :production, cluster_config, base_tags)

      expect(result).to have_key(:node_sa)
      expect(result[:node_sa].type).to eq('google_service_account')
    end

    it 'binds required IAM roles' do
      described_class.create_iam(ctx, :production, cluster_config, base_tags)

      iam_bindings = ctx.created_resources.select { |r| r[:type] == 'google_project_iam_member' }
      expect(iam_bindings.size).to eq(3)
    end
  end

  describe '.create_cluster' do
    let(:network_result) do
      described_class.create_network(ctx, :production, cluster_config, base_tags)
    end

    let(:arch_result) do
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:production, cluster_config)
      result.network = network_result
      result.iam = described_class.create_iam(ctx, :production, cluster_config, base_tags)
      result
    end

    it 'creates a GKE cluster' do
      cluster = described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)
      expect(cluster.type).to eq('google_container_cluster')
    end

    it 'removes default node pool' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      gke = ctx.find_resource(:google_container_cluster, :production_cluster)
      expect(gke[:attrs][:remove_default_node_pool]).to be true
      expect(gke[:attrs][:initial_node_count]).to eq(1)
    end

    it 'configures VPC-native networking' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      gke = ctx.find_resource(:google_container_cluster, :production_cluster)
      expect(gke[:attrs][:networking_mode]).to eq('VPC_NATIVE')
      expect(gke[:attrs][:ip_allocation_policy]).to include(
        cluster_secondary_range_name: 'production-pods'
      )
    end

    it 'configures private cluster' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      gke = ctx.find_resource(:google_container_cluster, :production_cluster)
      expect(gke[:attrs][:private_cluster_config][:enable_private_nodes]).to be true
    end

    it 'configures workload identity' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      gke = ctx.find_resource(:google_container_cluster, :production_cluster)
      expect(gke[:attrs][:workload_identity_config][:workload_pool]).to eq('my-project.svc.id.goog')
    end
  end

  describe '.create_node_pool' do
    let(:cluster_ref) { MockResourceRef.new('google_container_cluster', :production_cluster) }
    let(:pool_config) do
      Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :workers,
        instance_types: ['e2-standard-8'],
        min_size: 3,
        max_size: 20,
        disk_size_gb: 100
      )
    end

    it 'creates a GKE node pool' do
      ref = described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)
      expect(ref.type).to eq('google_container_node_pool')
    end

    it 'configures autoscaling' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      pool = ctx.find_resource(:google_container_node_pool, :production_workers)
      expect(pool[:attrs][:autoscaling][:min_node_count]).to eq(3)
      expect(pool[:attrs][:autoscaling][:max_node_count]).to eq(20)
    end

    it 'sets machine type and disk size' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      pool = ctx.find_resource(:google_container_node_pool, :production_workers)
      expect(pool[:attrs][:node_config][:machine_type]).to eq('e2-standard-8')
      expect(pool[:attrs][:node_config][:disk_size_gb]).to eq(100)
    end
  end
end
