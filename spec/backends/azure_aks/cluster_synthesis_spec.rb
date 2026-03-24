# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Backends::AzureAks do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'production', Backend: 'azure', ManagedBy: 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :azure,
      kubernetes_version: '1.29',
      region: 'eastus',
      resource_group_name: 'my-rg',
      dns_prefix: 'mycluster',
      node_pools: [
        { name: :system, instance_types: ['Standard_D4s_v3'], min_size: 2, max_size: 5 }
      ],
      network: { vpc_cidr: '10.0.0.0/16' }
    )
  end

  describe '.backend_name' do
    it 'returns :azure' do
      expect(described_class.backend_name).to eq(:azure)
    end
  end

  describe '.managed_kubernetes?' do
    it 'returns true' do
      expect(described_class.managed_kubernetes?).to be true
    end
  end

  describe '.create_network' do
    it 'creates resource group, VNet, and subnet' do
      result = described_class.create_network(ctx, :production, cluster_config, base_tags)

      expect(result).to have_key(:resource_group)
      expect(result[:resource_group].type).to eq('azurerm_resource_group')
      expect(result).to have_key(:vnet)
      expect(result[:vnet].type).to eq('azurerm_virtual_network')
      expect(result).to have_key(:subnet)
      expect(result[:subnet].type).to eq('azurerm_subnet')
    end

    it 'uses configured address space' do
      described_class.create_network(ctx, :production, cluster_config, base_tags)

      vnet = ctx.find_resource(:azurerm_virtual_network, :production_vnet)
      expect(vnet[:attrs][:address_space]).to eq(['10.0.0.0/16'])
    end
  end

  describe '.create_iam' do
    it 'returns empty IamResult (AKS uses managed identity)' do
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

    it 'creates an AKS cluster' do
      cluster = described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)
      expect(cluster.type).to eq('azurerm_kubernetes_cluster')
    end

    it 'includes default node pool in cluster resource' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      aks = ctx.find_resource(:azurerm_kubernetes_cluster, :production_cluster)
      default_pool = aks[:attrs][:default_node_pool]
      expect(default_pool).not_to be_nil
      expect(default_pool[:vm_size]).to eq('Standard_D4s_v3')
      expect(default_pool[:enable_auto_scaling]).to be true
    end

    it 'truncates node pool name to 12 chars' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      aks = ctx.find_resource(:azurerm_kubernetes_cluster, :production_cluster)
      expect(aks[:attrs][:default_node_pool][:name].length).to be <= 12
    end

    it 'configures SystemAssigned identity' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      aks = ctx.find_resource(:azurerm_kubernetes_cluster, :production_cluster)
      expect(aks[:attrs][:identity][:type]).to eq('SystemAssigned')
    end

    it 'sets dns_prefix from config' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      aks = ctx.find_resource(:azurerm_kubernetes_cluster, :production_cluster)
      expect(aks[:attrs][:dns_prefix]).to eq('mycluster')
    end
  end

  describe '.create_node_pool' do
    let(:cluster_ref) { MockResourceRef.new('azurerm_kubernetes_cluster', :production_cluster) }
    let(:pool_config) do
      Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :workers,
        instance_types: ['Standard_D8s_v3'],
        min_size: 3,
        max_size: 20
      )
    end

    it 'creates an AKS node pool' do
      ref = described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)
      expect(ref.type).to eq('azurerm_kubernetes_cluster_node_pool')
    end

    it 'configures autoscaling' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      pool = ctx.find_resource(:azurerm_kubernetes_cluster_node_pool, :production_workers)
      expect(pool[:attrs][:min_count]).to eq(3)
      expect(pool[:attrs][:max_count]).to eq(20)
      expect(pool[:attrs][:enable_auto_scaling]).to be true
    end

    it 'converts taints to AKS format' do
      tainted_pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :dedicated,
        instance_types: ['Standard_NC6'],
        taints: [{ key: 'gpu', value: 'true', effect: 'NoSchedule' }]
      )

      described_class.create_node_pool(ctx, :production, cluster_ref, tainted_pool, base_tags)
      pool = ctx.find_resource(:azurerm_kubernetes_cluster_node_pool, :production_dedicated)
      expect(pool[:attrs][:node_taints]).to eq(['gpu=true:NoSchedule'])
    end
  end
end
