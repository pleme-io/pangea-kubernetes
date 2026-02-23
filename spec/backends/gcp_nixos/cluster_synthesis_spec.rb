# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Backends::GcpNixos do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'production', Backend: 'gcp_nixos', ManagedBy: 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :gcp_nixos,
      kubernetes_version: '1.34',
      region: 'us-central1',
      project: 'my-project',
      distribution: :k3s,
      profile: 'cilium-standard',
      gce_image: 'nixos-24-05',
      node_pools: [
        { name: :system, instance_types: ['e2-standard-4'], min_size: 3, max_size: 3 }
      ],
      network: { vpc_cidr: '10.0.0.0/20' }
    )
  end

  describe '.backend_name' do
    it('returns :gcp_nixos') { expect(described_class.backend_name).to eq(:gcp_nixos) }
  end

  describe '.managed_kubernetes?' do
    it('returns false') { expect(described_class.managed_kubernetes?).to be false }
  end

  describe '.create_network' do
    it 'creates VPC, subnet, and firewall rules' do
      result = described_class.create_network(ctx, :production, cluster_config, base_tags)

      expect(result).to have_key(:vpc)
      expect(result).to have_key(:subnet)
      expect(result).to have_key(:firewall_internal)
      expect(result).to have_key(:firewall_external)
    end
  end

  describe '.create_iam' do
    it 'creates service account with minimal roles' do
      result = described_class.create_iam(ctx, :production, cluster_config, base_tags)

      expect(result).to have_key(:node_sa)
      iam_members = ctx.created_resources.select { |r| r[:type] == 'google_project_iam_member' }
      expect(iam_members.size).to eq(2)
    end
  end

  describe '.create_cluster' do
    let(:arch_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:production, cluster_config)
      r.network = described_class.create_network(ctx, :production, cluster_config, base_tags)
      r.iam = described_class.create_iam(ctx, :production, cluster_config, base_tags)
      r
    end

    it 'creates GCE instances (not GKE cluster)' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      instances = ctx.created_resources.select { |r| r[:type] == 'google_compute_instance' }
      expect(instances.size).to eq(3)
      expect(ctx.find_resource(:google_container_cluster, :production_cluster)).to be_nil
    end

    it 'uses NixOS image' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:google_compute_instance, :production_cp_0)
      expect(cp_0[:attrs][:boot_disk][:initialize_params][:image]).to eq('nixos-24-05')
    end

    it 'passes cloud-init via metadata' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:google_compute_instance, :production_cp_0)
      user_data = cp_0[:attrs][:metadata]['user-data']
      expect(user_data).to include('"distribution":"k3s"')
      expect(user_data).to include('"profile":"cilium-standard"')
    end
  end

  describe '.create_node_pool' do
    let(:cluster_ref) { MockResourceRef.new('google_compute_instance', :production_cp_0) }
    let(:pool_config) do
      Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :workers, instance_types: ['e2-standard-8'],
        min_size: 2, max_size: 20
      )
    end

    it 'creates Instance Template + MIG + Autoscaler (not GKE node pool)' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      template = ctx.find_resource(:google_compute_instance_template, :production_workers_template)
      mig = ctx.find_resource(:google_compute_instance_group_manager, :production_workers_mig)
      autoscaler = ctx.find_resource(:google_compute_autoscaler, :production_workers_autoscaler)

      expect(template).not_to be_nil
      expect(mig).not_to be_nil
      expect(autoscaler).not_to be_nil
    end

    it 'configures autoscaler with correct bounds' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      autoscaler = ctx.find_resource(:google_compute_autoscaler, :production_workers_autoscaler)
      policy = autoscaler[:attrs][:autoscaling_policy]
      expect(policy[:min_replicas]).to eq(2)
      expect(policy[:max_replicas]).to eq(20)
    end
  end
end
