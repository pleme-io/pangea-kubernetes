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
require 'pangea/kubernetes/backends/nixos_base'

module Pangea
  module Kubernetes
    module Backends
      # Hetzner Cloud NixOS backend.
      # Provisions NixOS VMs with cloud-init carrying blackmatter-kubernetes config.
      # Supports both k3s and vanilla Kubernetes distributions.
      module HcloudK3s
        include Base
        extend NixosBase

        class << self
          def backend_name = :hcloud
          def managed_kubernetes? = false
          def required_gem = 'pangea-hcloud'

          def load_provider!
            require required_gem
          rescue LoadError => e
            raise LoadError,
                  "Backend :hcloud requires gem 'pangea-hcloud'. " \
                  "Add it to your Gemfile: gem 'pangea-hcloud'\n" \
                  "Original error: #{e.message}"
          end

          # Create Hetzner Cloud network + subnet
          def create_network(ctx, name, config, tags)
            network = {}

            ip_range = config.network&.vpc_cidr || '10.0.0.0/16'
            network[:network] = ctx.hcloud_network(
              :"#{name}_network",
              name: "#{name}-network",
              ip_range: ip_range,
              labels: hcloud_labels(tags)
            )

            network[:subnet] = ctx.hcloud_network_subnet(
              :"#{name}_subnet",
              network_id: network[:network].id,
              type: 'cloud',
              network_zone: config.region,
              ip_range: config.network&.pod_cidr || '10.0.1.0/24'
            )

            network
          end

          # NixOS doesn't use cloud IAM — return empty
          def create_iam(_ctx, _name, _config, _tags)
            {}
          end

          # Create control plane server(s) as hcloud_server resources
          def create_cluster(ctx, name, config, result, tags)
            # Create firewall first
            ctx.hcloud_firewall(
              :"#{name}_firewall",
              name: "#{name}-firewall",
              rules: hcloud_firewall_rules(config.distribution),
              labels: hcloud_labels(tags)
            )

            nixos_create_cluster(ctx, name, config, result, tags)
          end

          # Create worker nodes as hcloud_server resources
          def create_node_pool(ctx, name, cluster_ref, pool_config, tags)
            # Hetzner doesn't have ASG — create individual servers
            server_type = pool_config.instance_types.first
            count = pool_config.effective_desired_size
            cloud_init = build_agent_cloud_init(name, tags, cluster_ref)

            servers = []
            count.times do |idx|
              server = ctx.hcloud_server(
                :"#{name}_#{pool_config.name}_#{idx}",
                name: "#{name}-#{pool_config.name}-#{idx}",
                server_type: server_type,
                image: 'ubuntu-24.04',
                location: tags[:Region] || 'nbg1',
                user_data: cloud_init,
                ssh_keys: pool_config.ssh_keys,
                labels: hcloud_labels(tags.merge(
                  Role: 'worker',
                  NodePool: pool_config.name.to_s,
                  NodeIndex: idx.to_s
                ))
              )

              servers << server
            end

            servers.first
          end

          # --- NixosBase template hooks ---

          def create_compute_instance(ctx, name, config, result, cloud_init, index, tags)
            system_pool = config.system_node_pool
            server_type = system_pool.instance_types.first
            firewall = result.network ? ctx.created_resources&.find { |r| r[:type] == 'hcloud_firewall' } : nil

            ctx.hcloud_server(
              :"#{name}_cp_#{index}",
              name: "#{name}-cp-#{index}",
              server_type: server_type,
              image: nixos_image(config),
              location: config.region,
              user_data: cloud_init,
              ssh_keys: system_pool.ssh_keys,
              firewall_ids: firewall ? [firewall[:ref].id] : [],
              labels: hcloud_labels(tags.merge(
                Role: 'control-plane',
                NodeIndex: index.to_s,
                Distribution: config.distribution.to_s
              ))
            )
          end

          # Override post_create_instance for Hetzner network attachment
          def post_create_instance(ctx, name, server, result, index, _tags)
            return unless result.network&.dig(:network)

            ctx.hcloud_server_network(
              :"#{name}_cp_#{index}_network",
              server_id: server.id,
              network_id: result.network[:network].id
            )
          end

          private

          def nixos_image(config)
            config.nixos&.image_id || 'ubuntu-24.04'
          end

          # Convert standard tags to Hetzner labels (lowercase, underscored)
          def hcloud_labels(tags)
            tags.transform_keys { |k| k.to_s.downcase.gsub(/[^a-z0-9_]/, '_') }
          end

          # Firewall rules for k3s or vanilla k8s
          def hcloud_firewall_rules(distribution)
            base_firewall_ports(distribution).map do |_name, port_def|
              source_ips = port_def[:public] ? ['0.0.0.0/0', '::/0'] : ['10.0.0.0/8']
              {
                direction: 'in',
                protocol: port_def[:protocol].to_s,
                port: port_def[:port].to_s,
                source_ips: source_ips
              }
            end
          end
        end
      end
    end
  end
end
