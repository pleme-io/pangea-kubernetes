# frozen_string_literal: true

RSpec.describe 'HcloudK3s node pool edge cases' do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'prod', Backend: 'hcloud', ManagedBy: 'Pangea' } }
  let(:cluster_ref) { MockResourceRef.new('hcloud_server', :prod_cp_0) }

  describe 'ssh_keys propagation' do
    it 'passes ssh_keys to worker servers' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :workers,
        instance_types: ['cx51'],
        min_size: 1,
        max_size: 5,
        ssh_keys: ['key-1', 'key-2']
      )
      Pangea::Kubernetes::Backends::HcloudK3s.create_node_pool(ctx, :prod, cluster_ref, pool, base_tags)
      worker = ctx.find_resource(:hcloud_server, :prod_workers_0)
      expect(worker[:attrs][:ssh_keys]).to eq(['key-1', 'key-2'])
    end
  end

  describe 'multiple workers' do
    it 'creates correct number of worker servers based on desired_size' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :workers,
        instance_types: ['cx51'],
        min_size: 1,
        max_size: 10,
        desired_size: 5
      )
      Pangea::Kubernetes::Backends::HcloudK3s.create_node_pool(ctx, :prod, cluster_ref, pool, base_tags)
      workers = ctx.created_resources.select { |r| r[:type] == 'hcloud_server' }
      expect(workers.size).to eq(5)
    end

    it 'defaults to min_size workers when no desired_size' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :workers,
        instance_types: ['cx51'],
        min_size: 3,
        max_size: 10
      )
      Pangea::Kubernetes::Backends::HcloudK3s.create_node_pool(ctx, :prod, cluster_ref, pool, base_tags)
      workers = ctx.created_resources.select { |r| r[:type] == 'hcloud_server' }
      expect(workers.size).to eq(3)
    end
  end

  describe 'worker labels' do
    it 'includes NodePool in labels' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :gpu,
        instance_types: ['cx51'],
        min_size: 1,
        max_size: 5
      )
      Pangea::Kubernetes::Backends::HcloudK3s.create_node_pool(ctx, :prod, cluster_ref, pool, base_tags)
      worker = ctx.find_resource(:hcloud_server, :prod_gpu_0)
      labels = worker[:attrs][:labels]
      expect(labels).to include('nodepool' => 'gpu')
      expect(labels).to include('role' => 'worker')
    end
  end

  describe 'join_server' do
    it 'includes join_server from cluster ref IP' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :workers,
        instance_types: ['cx51'],
        min_size: 1,
        max_size: 5
      )
      Pangea::Kubernetes::Backends::HcloudK3s.create_node_pool(ctx, :prod, cluster_ref, pool, base_tags)
      worker = ctx.find_resource(:hcloud_server, :prod_workers_0)
      expect(worker[:attrs][:user_data]).to include('"join_server"')
    end
  end

  describe 'with nixos image config' do
    it 'uses nixos image_id when available in config' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :hcloud,
        region: 'nbg1',
        distribution: :k3s,
        profile: 'cilium-standard',
        node_pools: [{ name: :system, instance_types: ['cx41'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        nixos: { image_id: 'nixos-custom-image' }
      )

      arch_result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      arch_result.network = Pangea::Kubernetes::Backends::HcloudK3s.create_network(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::HcloudK3s.create_cluster(ctx, :test, config, arch_result, base_tags)
      cp_0 = ctx.find_resource(:hcloud_server, :test_cp_0)
      expect(cp_0[:attrs][:image]).to eq('nixos-custom-image')
    end

    it 'falls back to ubuntu-24.04 when no nixos image_id' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :hcloud,
        region: 'nbg1',
        distribution: :k3s,
        profile: 'cilium-standard',
        node_pools: [{ name: :system, instance_types: ['cx41'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' }
      )

      arch_result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      arch_result.network = Pangea::Kubernetes::Backends::HcloudK3s.create_network(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::HcloudK3s.create_cluster(ctx, :test, config, arch_result, base_tags)
      cp_0 = ctx.find_resource(:hcloud_server, :test_cp_0)
      expect(cp_0[:attrs][:image]).to eq('ubuntu-24.04')
    end
  end

  describe 'fluxcd config propagation through cluster creation' do
    it 'includes fluxcd config in cloud-init when present' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :hcloud,
        region: 'nbg1',
        distribution: :k3s,
        profile: 'cilium-standard',
        node_pools: [{ name: :system, instance_types: ['cx41'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        fluxcd: {
          source_url: 'ssh://git@github.com/org/k8s.git',
          reconcile_path: 'clusters/prod'
        }
      )

      arch_result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      arch_result.network = Pangea::Kubernetes::Backends::HcloudK3s.create_network(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::HcloudK3s.create_cluster(ctx, :test, config, arch_result, base_tags)
      cp_0 = ctx.find_resource(:hcloud_server, :test_cp_0)
      expect(cp_0[:attrs][:user_data]).to include('"fluxcd"')
      expect(cp_0[:attrs][:user_data]).to include('org/k8s.git')
    end
  end

  describe 'cluster without network' do
    it 'skips network attachment when no network result' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :hcloud,
        region: 'nbg1',
        distribution: :k3s,
        profile: 'cilium-standard',
        node_pools: [{ name: :system, instance_types: ['cx41'], min_size: 1, max_size: 1 }]
      )

      arch_result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      # no network set

      Pangea::Kubernetes::Backends::HcloudK3s.create_cluster(ctx, :test, config, arch_result, base_tags)
      network_attachments = ctx.created_resources.select { |r| r[:type] == 'hcloud_server_network' }
      expect(network_attachments.size).to eq(0)
    end
  end
end
