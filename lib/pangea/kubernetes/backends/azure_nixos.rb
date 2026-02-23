# frozen_string_literal: true

# Copyright 2025 The Pangea Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'pangea/kubernetes/backends/base'
require 'pangea/kubernetes/bare_metal/cloud_init'

module Pangea
  module Kubernetes
    module Backends
      # Azure NixOS backend — Azure VMs running NixOS with k3s/k8s
      # via blackmatter-kubernetes modules.
      #
      # Uses:
      #   - Azure VMs for control plane (static)
      #   - VM Scale Sets (VMSS) for worker node pools
      #   - VNet + NSG for networking
      #
      # No managed K8s services (AKS) — all k3s/k8s managed by NixOS.
      module AzureNixos
        include Base

        class << self
          def backend_name = :azure_nixos
          def managed_kubernetes? = false
          def required_gem = 'pangea-azure'

          def load_provider!
            require required_gem
          rescue LoadError => e
            raise LoadError,
                  "Backend :azure_nixos requires gem 'pangea-azure'. " \
                  "Add it to your Gemfile: gem 'pangea-azure'\n" \
                  "Original error: #{e.message}"
          end

          # Create Resource Group + VNet + Subnet + NSG
          def create_network(ctx, name, config, tags)
            network = {}

            network[:resource_group] = ctx.azurerm_resource_group(
              :"#{name}_rg",
              name: "#{name}-rg",
              location: config.region,
              tags: tags
            )

            network[:vnet] = ctx.azurerm_virtual_network(
              :"#{name}_vnet",
              name: "#{name}-vnet",
              resource_group_name: network[:resource_group].name,
              location: config.region,
              address_space: [config.network&.vpc_cidr || '10.0.0.0/16'],
              tags: tags
            )

            network[:subnet] = ctx.azurerm_subnet(
              :"#{name}_subnet",
              name: "#{name}-subnet",
              resource_group_name: network[:resource_group].name,
              virtual_network_name: network[:vnet].name,
              address_prefixes: [config.network&.pod_cidr || '10.0.1.0/24']
            )

            # Network Security Group
            network[:nsg] = ctx.azurerm_network_security_group(
              :"#{name}_nsg",
              name: "#{name}-nsg",
              resource_group_name: network[:resource_group].name,
              location: config.region,
              security_rule: nsg_rules(config.distribution),
              tags: tags
            )

            # Associate NSG with subnet
            ctx.azurerm_subnet_network_security_group_association(
              :"#{name}_nsg_assoc",
              subnet_id: network[:subnet].id,
              network_security_group_id: network[:nsg].id
            )

            network
          end

          # No standalone IAM — Azure VMs use Managed Identity
          def create_iam(_ctx, _name, _config, _tags)
            {}
          end

          # Create control plane Azure VMs (static)
          def create_cluster(ctx, name, config, result, tags)
            system_pool = config.system_node_pool
            vm_size = system_pool.instance_types.first
            image_id = config.azure_image_id || config.nixos&.image_id
            rg_name = config.resource_group_name || result.network&.dig(:resource_group)&.name || "#{name}-rg"

            cp_count = [system_pool.min_size, 1].max
            servers = []

            cp_count.times do |idx|
              cloud_init = BareMetal::CloudInit.generate(
                cluster_name: name.to_s,
                distribution: config.distribution,
                profile: config.profile,
                distribution_track: config.distribution_track || config.kubernetes_version,
                role: 'server',
                node_index: idx,
                cluster_init: idx.zero?,
                fluxcd: config.fluxcd&.to_h
              )

              # Network interface
              nic = ctx.azurerm_network_interface(
                :"#{name}_cp_#{idx}_nic",
                name: "#{name}-cp-#{idx}-nic",
                resource_group_name: rg_name,
                location: config.region,
                ip_configuration: {
                  name: 'internal',
                  subnet_id: result.network&.dig(:subnet)&.id,
                  private_ip_address_allocation: 'Dynamic',
                  public_ip_address_id: nil
                },
                tags: tags
              )

              server = ctx.azurerm_linux_virtual_machine(
                :"#{name}_cp_#{idx}",
                name: "#{name}-cp-#{idx}",
                resource_group_name: rg_name,
                location: config.region,
                size: vm_size,
                network_interface_ids: [nic.id],
                admin_username: 'nixos',
                admin_ssh_key: {
                  username: 'nixos',
                  public_key: '${file("~/.ssh/id_ed25519.pub")}'
                },
                os_disk: {
                  caching: 'ReadWrite',
                  storage_account_type: 'Premium_LRS',
                  disk_size_gb: system_pool.disk_size_gb
                },
                source_image_id: image_id,
                custom_data: cloud_init,
                identity: { type: 'SystemAssigned' },
                tags: tags.merge(
                  Role: 'control-plane',
                  NodeIndex: idx.to_s,
                  Distribution: config.distribution.to_s
                )
              )

              servers << server
            end

            servers.first
          end

          # Create worker node pool via VMSS (VM Scale Set)
          def create_node_pool(ctx, name, cluster_ref, pool_config, tags)
            pool_name = :"#{name}_#{pool_config.name}"
            vm_size = pool_config.instance_types.first

            cloud_init = BareMetal::CloudInit.generate(
              cluster_name: name.to_s,
              distribution: tags[:Distribution]&.to_sym || :k3s,
              profile: tags[:Profile] || 'cilium-standard',
              distribution_track: tags[:DistributionTrack] || '1.34',
              role: 'agent',
              node_index: 0,
              cluster_init: false,
              join_server: cluster_ref.ipv4_address
            )

            vmss = ctx.azurerm_linux_virtual_machine_scale_set(
              pool_name,
              name: "#{name}-#{pool_config.name}-vmss",
              resource_group_name: tags[:ResourceGroupName] || "#{name}-rg",
              location: tags[:Region] || 'eastus',
              sku: vm_size,
              instances: pool_config.effective_desired_size,
              admin_username: 'nixos',
              admin_ssh_key: {
                username: 'nixos',
                public_key: '${file("~/.ssh/id_ed25519.pub")}'
              },
              os_disk: {
                caching: 'ReadWrite',
                storage_account_type: 'Premium_LRS',
                disk_size_gb: pool_config.disk_size_gb
              },
              source_image_id: tags[:ImageId],
              custom_data: cloud_init,
              network_interface: {
                name: "#{name}-#{pool_config.name}-nic",
                primary: true,
                ip_configuration: {
                  name: 'internal',
                  subnet_id: tags[:SubnetId],
                  primary: true
                }
              },
              identity: { type: 'SystemAssigned' },
              tags: tags.merge(
                NodePool: pool_config.name.to_s,
                Role: 'worker'
              )
            )

            # Autoscale setting
            ctx.azurerm_monitor_autoscale_setting(
              :"#{pool_name}_autoscale",
              name: "#{name}-#{pool_config.name}-autoscale",
              resource_group_name: tags[:ResourceGroupName] || "#{name}-rg",
              location: tags[:Region] || 'eastus',
              target_resource_id: vmss.id,
              profile: {
                name: 'default',
                capacity: {
                  default: pool_config.effective_desired_size,
                  minimum: pool_config.min_size,
                  maximum: pool_config.max_size
                },
                rule: [{
                  metric_trigger: {
                    metric_name: 'Percentage CPU',
                    metric_resource_id: vmss.id,
                    operator: 'GreaterThan',
                    threshold: 70,
                    time_aggregation: 'Average',
                    time_grain: 'PT1M',
                    time_window: 'PT5M',
                    statistic: 'Average'
                  },
                  scale_action: {
                    direction: 'Increase',
                    type: 'ChangeCount',
                    value: 1,
                    cooldown: 'PT5M'
                  }
                }]
              }
            )

            vmss
          end

          private

          def nsg_rules(distribution)
            rules = [
              { name: 'SSH', priority: 100, direction: 'Inbound', access: 'Allow', protocol: 'Tcp',
                source_port_range: '*', destination_port_range: '22', source_address_prefix: '*', destination_address_prefix: '*' },
              { name: 'HTTP', priority: 110, direction: 'Inbound', access: 'Allow', protocol: 'Tcp',
                source_port_range: '*', destination_port_range: '80', source_address_prefix: '*', destination_address_prefix: '*' },
              { name: 'HTTPS', priority: 120, direction: 'Inbound', access: 'Allow', protocol: 'Tcp',
                source_port_range: '*', destination_port_range: '443', source_address_prefix: '*', destination_address_prefix: '*' },
              { name: 'K8sAPI', priority: 130, direction: 'Inbound', access: 'Allow', protocol: 'Tcp',
                source_port_range: '*', destination_port_range: '6443', source_address_prefix: '*', destination_address_prefix: '*' },
              { name: 'Kubelet', priority: 140, direction: 'Inbound', access: 'Allow', protocol: 'Tcp',
                source_port_range: '*', destination_port_range: '10250', source_address_prefix: '10.0.0.0/8', destination_address_prefix: '*' },
              { name: 'etcd', priority: 150, direction: 'Inbound', access: 'Allow', protocol: 'Tcp',
                source_port_range: '*', destination_port_range: '2379-2380', source_address_prefix: '10.0.0.0/8', destination_address_prefix: '*' },
              { name: 'VXLAN', priority: 160, direction: 'Inbound', access: 'Allow', protocol: 'Udp',
                source_port_range: '*', destination_port_range: '8472', source_address_prefix: '10.0.0.0/8', destination_address_prefix: '*' }
            ]

            if distribution.to_sym == :kubernetes
              rules += [
                { name: 'ControllerManager', priority: 170, direction: 'Inbound', access: 'Allow', protocol: 'Tcp',
                  source_port_range: '*', destination_port_range: '10257', source_address_prefix: '10.0.0.0/8', destination_address_prefix: '*' },
                { name: 'Scheduler', priority: 180, direction: 'Inbound', access: 'Allow', protocol: 'Tcp',
                  source_port_range: '*', destination_port_range: '10259', source_address_prefix: '10.0.0.0/8', destination_address_prefix: '*' }
              ]
            end

            rules
          end
        end
      end
    end
  end
end
