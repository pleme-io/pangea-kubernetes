# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Backends::AzureNixos do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'production', Backend: 'azure_nixos', ManagedBy: 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :azure_nixos,
      kubernetes_version: '1.34',
      region: 'eastus',
      distribution: :k3s,
      profile: 'cilium-standard',
      azure_image_id: '/subscriptions/.../images/nixos-24-05',
      node_pools: [
        { name: :system, instance_types: ['Standard_D4s_v3'], min_size: 3, max_size: 3 }
      ],
      network: { vpc_cidr: '10.0.0.0/16' }
    )
  end

  describe '.backend_name' do
    it('returns :azure_nixos') { expect(described_class.backend_name).to eq(:azure_nixos) }
  end

  describe '.managed_kubernetes?' do
    it('returns false') { expect(described_class.managed_kubernetes?).to be false }
  end

  describe '.create_network' do
    it 'creates resource group, VNet, subnet, and NSG' do
      result = described_class.create_network(ctx, :production, cluster_config, base_tags)

      expect(result).to have_key(:resource_group)
      expect(result).to have_key(:vnet)
      expect(result).to have_key(:subnet)
      expect(result).to have_key(:nsg)
    end

    it 'creates NSG rules for K8s ports' do
      described_class.create_network(ctx, :production, cluster_config, base_tags)

      nsg = ctx.find_resource(:azurerm_network_security_group, :production_nsg)
      rules = nsg[:attrs][:security_rule]
      api_rule = rules.find { |r| r[:name] == 'K8sAPI' }
      expect(api_rule[:destination_port_range]).to eq('6443')
    end

    it 'associates NSG with subnet' do
      described_class.create_network(ctx, :production, cluster_config, base_tags)

      assoc = ctx.find_resource(:azurerm_subnet_network_security_group_association, :production_nsg_assoc)
      expect(assoc).not_to be_nil
    end
  end

  describe '.create_iam' do
    it 'returns empty hash (Azure uses managed identity)' do
      result = described_class.create_iam(ctx, :production, cluster_config, base_tags)
      expect(result).to eq({})
    end
  end

  describe '.create_cluster' do
    let(:arch_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:production, cluster_config)
      r.network = described_class.create_network(ctx, :production, cluster_config, base_tags)
      r
    end

    it 'creates Azure Linux VMs (not AKS)' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      vms = ctx.created_resources.select { |r| r[:type] == 'azurerm_linux_virtual_machine' }
      expect(vms.size).to eq(3)
      expect(ctx.find_resource(:azurerm_kubernetes_cluster, :production_cluster)).to be_nil
    end

    it 'creates NICs for each VM' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      nics = ctx.created_resources.select { |r| r[:type] == 'azurerm_network_interface' }
      expect(nics.size).to eq(3)
    end

    it 'uses NixOS image' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:azurerm_linux_virtual_machine, :production_cp_0)
      expect(cp_0[:attrs][:source_image_id]).to eq('/subscriptions/.../images/nixos-24-05')
    end

    it 'passes cloud-init via custom_data' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:azurerm_linux_virtual_machine, :production_cp_0)
      custom_data = cp_0[:attrs][:custom_data]
      expect(custom_data).to include('"distribution":"k3s"')
      expect(custom_data).to include('"profile":"cilium-standard"')
    end

    it 'sets SystemAssigned identity on VMs' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:azurerm_linux_virtual_machine, :production_cp_0)
      expect(cp_0[:attrs][:identity][:type]).to eq('SystemAssigned')
    end
  end

  describe '.create_node_pool' do
    let(:cluster_ref) { MockResourceRef.new('azurerm_linux_virtual_machine', :production_cp_0) }
    let(:pool_config) do
      Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :workers, instance_types: ['Standard_D8s_v3'],
        min_size: 2, max_size: 20
      )
    end

    it 'creates VMSS + Autoscale setting (not AKS node pool)' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      vmss = ctx.find_resource(:azurerm_linux_virtual_machine_scale_set, :production_workers)
      autoscale = ctx.find_resource(:azurerm_monitor_autoscale_setting, :production_workers_autoscale)

      expect(vmss).not_to be_nil
      expect(autoscale).not_to be_nil
    end

    it 'configures autoscale with correct bounds' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      autoscale = ctx.find_resource(:azurerm_monitor_autoscale_setting, :production_workers_autoscale)
      capacity = autoscale[:attrs][:profile][:capacity]
      expect(capacity[:minimum]).to eq(2)
      expect(capacity[:maximum]).to eq(20)
    end
  end
end
