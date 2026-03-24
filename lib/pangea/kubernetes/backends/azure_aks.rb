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

module Pangea
  module Kubernetes
    module Backends
      # Azure AKS backend — creates managed AKS clusters.
      # AKS bundles default node pool with the cluster resource,
      # so create_cluster handles both.
      module AzureAks
        include Base

        class << self
          def backend_name = :azure
          def managed_kubernetes? = true
          def required_gem = 'pangea-azure'

          def load_provider!
            require required_gem
          rescue LoadError => e
            raise LoadError,
                  "Backend :azure requires gem 'pangea-azure'. " \
                  "Add it to your Gemfile: gem 'pangea-azure'\n" \
                  "Original error: #{e.message}"
          end

          # Create Azure VNet + subnet
          def create_network(ctx, name, config, tags)
            network = Architecture::AzureNetworkResult.new

            network.resource_group = ctx.azurerm_resource_group(
              :"#{name}_rg",
              name: "#{name}-rg",
              location: config.region,
              tags: tags
            )

            network.vnet = ctx.azurerm_virtual_network(
              :"#{name}_vnet",
              name: "#{name}-vnet",
              resource_group_name: network.resource_group.name,
              location: config.region,
              address_space: [config.network&.vpc_cidr || '10.0.0.0/16'],
              tags: tags
            )
            network.vpc = network.vnet

            subnet = ctx.azurerm_subnet(
              :"#{name}_subnet",
              name: "#{name}-subnet",
              resource_group_name: network.resource_group.name,
              virtual_network_name: network.vnet.name,
              address_prefixes: [config.network&.pod_cidr || '10.0.1.0/24']
            )
            network.add_subnet(:subnet, subnet)

            network
          end

          # AKS uses managed identity — no standalone IAM resources needed
          def create_iam(_ctx, _name, _config, _tags)
            Architecture::IamResult.new
          end

          # Create AKS cluster with default node pool
          def create_cluster(ctx, name, config, result, tags)
            system_pool = config.system_node_pool
            rg_name = config.resource_group_name || result.network&.dig(:resource_group)&.name || "#{name}-rg"
            dns_prefix = config.dns_prefix || name.to_s

            cluster_attrs = {
              name: "#{name}-cluster",
              resource_group_name: rg_name,
              location: config.region,
              dns_prefix: dns_prefix,
              kubernetes_version: config.kubernetes_version,
              default_node_pool: {
                name: system_pool.name.to_s[0..11], # AKS max 12 chars
                vm_size: system_pool.instance_types.first,
                node_count: system_pool.effective_desired_size,
                min_count: system_pool.min_size,
                max_count: system_pool.max_size,
                enable_auto_scaling: true,
                os_disk_size_gb: system_pool.disk_size_gb
              },
              identity: { type: 'SystemAssigned' },
              tags: tags
            }

            cluster_attrs[:sku_tier] = 'Standard' if tags[:Environment] == 'production'

            # Network profile
            if result.network&.dig(:subnet)
              cluster_attrs[:default_node_pool][:vnet_subnet_id] = result.network[:subnet].id
            end

            ctx.azurerm_kubernetes_cluster(:"#{name}_cluster", cluster_attrs)
          end

          # Create additional AKS node pool
          def create_node_pool(ctx, name, cluster_ref, pool_config, tags)
            pool_name = :"#{name}_#{pool_config.name}"

            node_pool_attrs = {
              name: pool_config.name.to_s[0..11], # AKS max 12 chars
              kubernetes_cluster_id: cluster_ref.id,
              vm_size: pool_config.instance_types.first,
              node_count: pool_config.effective_desired_size,
              min_count: pool_config.min_size,
              max_count: pool_config.max_size,
              enable_auto_scaling: true,
              os_disk_size_gb: pool_config.disk_size_gb,
              tags: tags.merge(NodePool: pool_config.name.to_s)
            }

            node_pool_attrs[:node_labels] = pool_config.labels if pool_config.labels.any?

            if pool_config.taints.any?
              node_pool_attrs[:node_taints] = pool_config.taints.map do |t|
                "#{t[:key]}=#{t[:value]}:#{t[:effect]}"
              end
            end

            ctx.azurerm_kubernetes_cluster_node_pool(pool_name, node_pool_attrs)
          end
        end
      end
    end
  end
end
