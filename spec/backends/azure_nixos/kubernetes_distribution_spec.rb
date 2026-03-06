# frozen_string_literal: true

RSpec.describe 'Azure NixOS kubernetes distribution' do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'test', Backend: 'azure_nixos', ManagedBy: 'Pangea' } }

  describe 'vanilla kubernetes distribution' do
    let(:k8s_config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :azure_nixos,
        kubernetes_version: '1.34',
        region: 'eastus',
        distribution: :kubernetes,
        profile: 'calico-standard',
        azure_image_id: '/subscriptions/.../images/nixos-24-05',
        node_pools: [
          { name: :system, instance_types: ['Standard_D4s_v3'], min_size: 3, max_size: 3 }
        ],
        network: { vpc_cidr: '10.0.0.0/16' }
      )
    end

    it 'creates NSG with kubernetes-specific rules (controller-manager, scheduler)' do
      Pangea::Kubernetes::Backends::AzureNixos.create_network(ctx, :test, k8s_config, base_tags)
      nsg = ctx.find_resource(:azurerm_network_security_group, :test_nsg)
      rules = nsg[:attrs][:security_rule]
      controller_rule = rules.find { |r| r[:name] == 'ControllerManager' }
      scheduler_rule = rules.find { |r| r[:name] == 'Scheduler' }
      expect(controller_rule).not_to be_nil
      expect(controller_rule[:destination_port_range]).to eq('10257')
      expect(scheduler_rule).not_to be_nil
      expect(scheduler_rule[:destination_port_range]).to eq('10259')
    end

    it 'includes kubernetes distribution in cloud-init' do
      arch_result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, k8s_config)
      arch_result.network = Pangea::Kubernetes::Backends::AzureNixos.create_network(ctx, :test, k8s_config, base_tags)

      Pangea::Kubernetes::Backends::AzureNixos.create_cluster(ctx, :test, k8s_config, arch_result, base_tags)
      cp_0 = ctx.find_resource(:azurerm_linux_virtual_machine, :test_cp_0)
      custom_data = cp_0[:attrs][:custom_data]
      expect(custom_data).to include('"distribution":"kubernetes"')
      # vanilla k8s normalizes server -> control-plane
      expect(custom_data).to include('"role":"control-plane"')
    end

    it 'creates worker VMSS with kubernetes distribution' do
      cluster_ref = MockResourceRef.new('azurerm_linux_virtual_machine', :test_cp_0)
      pool_config = Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :workers,
        instance_types: ['Standard_D8s_v3'],
        min_size: 2,
        max_size: 10
      )
      tags = base_tags.merge(Distribution: 'kubernetes')

      Pangea::Kubernetes::Backends::AzureNixos.create_node_pool(ctx, :test, cluster_ref, pool_config, tags)
      vmss = ctx.find_resource(:azurerm_linux_virtual_machine_scale_set, :test_workers)
      custom_data = vmss[:attrs][:custom_data]
      expect(custom_data).to include('"distribution":"kubernetes"')
      # agent -> worker for kubernetes
      expect(custom_data).to include('"role":"worker"')
    end
  end

  describe 'cluster with fluxcd' do
    it 'includes fluxcd in cloud-init' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :azure_nixos,
        kubernetes_version: '1.34',
        region: 'eastus',
        distribution: :k3s,
        profile: 'cilium-standard',
        azure_image_id: '/subscriptions/.../images/nixos-24-05',
        node_pools: [{ name: :system, instance_types: ['Standard_D4s_v3'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        fluxcd: { source_url: 'ssh://git@github.com/org/k8s.git' }
      )

      arch_result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      arch_result.network = Pangea::Kubernetes::Backends::AzureNixos.create_network(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AzureNixos.create_cluster(ctx, :test, config, arch_result, base_tags)
      cp_0 = ctx.find_resource(:azurerm_linux_virtual_machine, :test_cp_0)
      expect(cp_0[:attrs][:custom_data]).to include('"fluxcd"')
    end
  end

  describe 'resource_group_name resolution' do
    it 'uses config resource_group_name when provided' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :azure_nixos,
        kubernetes_version: '1.34',
        region: 'eastus',
        resource_group_name: 'custom-rg',
        distribution: :k3s,
        profile: 'cilium-standard',
        azure_image_id: '/subscriptions/.../images/nixos',
        node_pools: [{ name: :system, instance_types: ['Standard_D4s_v3'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' }
      )

      arch_result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      arch_result.network = Pangea::Kubernetes::Backends::AzureNixos.create_network(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AzureNixos.create_cluster(ctx, :test, config, arch_result, base_tags)
      cp_nic = ctx.find_resource(:azurerm_network_interface, :test_cp_0_nic)
      expect(cp_nic[:attrs][:resource_group_name]).to eq('custom-rg')
    end

    it 'falls back to network resource_group name' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :azure_nixos,
        kubernetes_version: '1.34',
        region: 'eastus',
        distribution: :k3s,
        profile: 'cilium-standard',
        azure_image_id: '/subscriptions/.../images/nixos',
        node_pools: [{ name: :system, instance_types: ['Standard_D4s_v3'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' }
      )

      arch_result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      arch_result.network = Pangea::Kubernetes::Backends::AzureNixos.create_network(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AzureNixos.create_cluster(ctx, :test, config, arch_result, base_tags)
      # Should use the resource group name from the network result
      cp_nic = ctx.find_resource(:azurerm_network_interface, :test_cp_0_nic)
      expect(cp_nic[:attrs][:resource_group_name]).not_to be_nil
    end
  end
end
