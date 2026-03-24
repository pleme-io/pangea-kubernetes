# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Backends::HcloudK3s do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'production', Backend: 'hcloud', ManagedBy: 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :hcloud,
      kubernetes_version: '1.34',
      region: 'nbg1',
      distribution: :k3s,
      profile: 'cilium-standard',
      distribution_track: '1.34',
      node_pools: [
        { name: :system, instance_types: ['cx41'], min_size: 3, max_size: 3, ssh_keys: ['my-key'] },
        { name: :workers, instance_types: ['cx51'], min_size: 2, max_size: 10 }
      ],
      network: { vpc_cidr: '10.0.0.0/16' }
    )
  end

  describe '.backend_name' do
    it 'returns :hcloud' do
      expect(described_class.backend_name).to eq(:hcloud)
    end
  end

  describe '.managed_kubernetes?' do
    it 'returns false' do
      expect(described_class.managed_kubernetes?).to be false
    end
  end

  describe '.create_network' do
    it 'creates network and subnet' do
      result = described_class.create_network(ctx, :production, cluster_config, base_tags)

      expect(result).to have_key(:network)
      expect(result[:network].type).to eq('hcloud_network')
      expect(result).to have_key(:subnet)
      expect(result[:subnet].type).to eq('hcloud_network_subnet')
    end

    it 'uses configured IP range' do
      described_class.create_network(ctx, :production, cluster_config, base_tags)
      network = ctx.find_resource(:hcloud_network, :production_network)
      expect(network[:attrs][:ip_range]).to eq('10.0.0.0/16')
    end
  end

  describe '.create_iam' do
    it 'returns empty IamResult (NixOS uses no cloud IAM)' do
      result = described_class.create_iam(ctx, :production, cluster_config, base_tags)
      expect(result).to be_a(Pangea::Contracts::IamResult)
      expect(result.to_h).to eq({})
    end
  end

  describe '.create_cluster' do
    let(:network_result) do
      described_class.create_network(ctx, :production, cluster_config, base_tags)
    end

    let(:arch_result) do
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:production, cluster_config)
      result.network = network_result
      result
    end

    it 'creates firewall with k3s rules' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      firewall = ctx.find_resource(:hcloud_firewall, :production_firewall)
      expect(firewall).not_to be_nil
      expect(firewall[:attrs][:rules]).to be_an(Array)
      api_rule = firewall[:attrs][:rules].find { |r| r[:port] == '6443' }
      expect(api_rule).not_to be_nil
    end

    it 'creates control plane servers' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_servers = ctx.created_resources.select { |r| r[:type] == 'hcloud_server' }
      expect(cp_servers.size).to eq(3)
    end

    it 'sets first server as cluster-init' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:hcloud_server, :production_cp_0)
      user_data = cp_0[:attrs][:user_data]
      expect(user_data).to include('"cluster_init":true')
    end

    it 'sets subsequent servers as non-init' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_1 = ctx.find_resource(:hcloud_server, :production_cp_1)
      user_data = cp_1[:attrs][:user_data]
      expect(user_data).to include('"cluster_init":false')
    end

    it 'includes distribution and profile in cloud-init' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:hcloud_server, :production_cp_0)
      user_data = cp_0[:attrs][:user_data]
      expect(user_data).to include('"distribution":"k3s"')
      expect(user_data).to include('"profile":"cilium-standard"')
      expect(user_data).to include('"distribution_track":"1.34"')
    end

    it 'attaches servers to network' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      network_attachments = ctx.created_resources.select { |r| r[:type] == 'hcloud_server_network' }
      expect(network_attachments.size).to eq(3)
    end

    it 'passes SSH keys from system node pool' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:hcloud_server, :production_cp_0)
      expect(cp_0[:attrs][:ssh_keys]).to eq(['my-key'])
    end

    context 'with vanilla kubernetes distribution' do
      let(:k8s_config) do
        Pangea::Kubernetes::Types::ClusterConfig.new(
          backend: :hcloud,
          kubernetes_version: '1.34',
          region: 'nbg1',
          distribution: :kubernetes,
          profile: 'calico-standard',
          distribution_track: '1.34',
          node_pools: [
            { name: :system, instance_types: ['cx41'], min_size: 3, max_size: 3 }
          ],
          network: { vpc_cidr: '10.0.0.0/16' }
        )
      end

      let(:k8s_arch_result) do
        r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, k8s_config)
        r.network = described_class.create_network(ctx, :test, k8s_config, base_tags)
        r
      end

      it 'creates firewall with kubernetes-specific rules' do
        described_class.create_cluster(ctx, :test, k8s_config, k8s_arch_result, base_tags)

        firewall = ctx.find_resource(:hcloud_firewall, :test_firewall)
        rules = firewall[:attrs][:rules]
        controller_rule = rules.find { |r| r[:port] == '10257' }
        scheduler_rule = rules.find { |r| r[:port] == '10259' }
        expect(controller_rule).not_to be_nil
        expect(scheduler_rule).not_to be_nil
      end

      it 'includes kubernetes distribution in cloud-init' do
        described_class.create_cluster(ctx, :test, k8s_config, k8s_arch_result, base_tags)

        cp_0 = ctx.find_resource(:hcloud_server, :test_cp_0)
        user_data = cp_0[:attrs][:user_data]
        expect(user_data).to include('"distribution":"kubernetes"')
        expect(user_data).to include('"profile":"calico-standard"')
      end
    end
  end

  describe '.create_node_pool' do
    let(:cluster_ref) { MockResourceRef.new('hcloud_server', :production_cp_0) }
    let(:pool_config) do
      Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :workers,
        instance_types: ['cx51'],
        min_size: 2,
        max_size: 10,
        desired_size: 3
      )
    end

    it 'creates worker servers' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      worker_servers = ctx.created_resources.select { |r| r[:type] == 'hcloud_server' }
      expect(worker_servers.size).to eq(3)
    end

    it 'sets role to agent in cloud-init' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      worker_0 = ctx.find_resource(:hcloud_server, :production_workers_0)
      user_data = worker_0[:attrs][:user_data]
      expect(user_data).to include('"role":"agent"')
    end
  end
end
