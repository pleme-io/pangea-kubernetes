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
      # Hetzner Cloud NixOS backend.
      # Provisions NixOS VMs with cloud-init carrying blackmatter-kubernetes config.
      # Supports both k3s and vanilla Kubernetes distributions.
      module HcloudK3s
        include Base

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
            system_pool = config.system_node_pool
            server_type = system_pool.instance_types.first

            # Create firewall
            firewall = ctx.hcloud_firewall(
              :"#{name}_firewall",
              name: "#{name}-firewall",
              rules: firewall_rules(config.distribution),
              labels: hcloud_labels(tags)
            )

            # Create control plane servers
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
                network_id: result.network&.dig(:network)&.id,
                fluxcd: config.fluxcd&.to_h
              )

              server = ctx.hcloud_server(
                :"#{name}_cp_#{idx}",
                name: "#{name}-cp-#{idx}",
                server_type: server_type,
                image: nixos_image(config),
                location: config.region,
                user_data: cloud_init,
                ssh_keys: system_pool.ssh_keys,
                firewall_ids: [firewall.id],
                labels: hcloud_labels(tags.merge(
                  Role: 'control-plane',
                  NodeIndex: idx.to_s,
                  Distribution: config.distribution.to_s
                ))
              )

              # Attach to network if created
              if result.network&.dig(:network)
                ctx.hcloud_server_network(
                  :"#{name}_cp_#{idx}_network",
                  server_id: server.id,
                  network_id: result.network[:network].id
                )
              end

              servers << server
            end

            servers.first
          end

          # Create worker nodes as hcloud_server resources
          def create_node_pool(ctx, name, cluster_ref, pool_config, tags)
            server_type = pool_config.instance_types.first
            count = pool_config.effective_desired_size

            servers = []
            count.times do |idx|
              cloud_init = BareMetal::CloudInit.generate(
                cluster_name: name.to_s,
                distribution: tags[:Distribution]&.to_sym || :k3s,
                profile: tags[:Profile] || 'cilium-standard',
                distribution_track: tags[:DistributionTrack] || '1.34',
                role: 'agent',
                node_index: idx,
                cluster_init: false,
                join_server: cluster_ref.ipv4_address
              )

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

          private

          def nixos_image(config)
            config.nixos&.image_id || 'ubuntu-24.04'
          end

          # Convert standard tags to Hetzner labels (lowercase, underscored)
          def hcloud_labels(tags)
            tags.transform_keys { |k| k.to_s.downcase.gsub(/[^a-z0-9_]/, '_') }
          end

          # Firewall rules for k3s or vanilla k8s
          def firewall_rules(distribution)
            rules = [
              { direction: 'in', protocol: 'tcp', port: '22', source_ips: ['0.0.0.0/0', '::/0'] },
              { direction: 'in', protocol: 'tcp', port: '80', source_ips: ['0.0.0.0/0', '::/0'] },
              { direction: 'in', protocol: 'tcp', port: '443', source_ips: ['0.0.0.0/0', '::/0'] },
              { direction: 'in', protocol: 'tcp', port: '10250', source_ips: ['10.0.0.0/8'] }
            ]

            case distribution.to_sym
            when :k3s
              rules += [
                { direction: 'in', protocol: 'tcp', port: '6443', source_ips: ['0.0.0.0/0', '::/0'] },
                { direction: 'in', protocol: 'udp', port: '8472', source_ips: ['10.0.0.0/8'] },
                { direction: 'in', protocol: 'tcp', port: '2379-2380', source_ips: ['10.0.0.0/8'] }
              ]
            when :kubernetes
              rules += [
                { direction: 'in', protocol: 'tcp', port: '6443', source_ips: ['0.0.0.0/0', '::/0'] },
                { direction: 'in', protocol: 'tcp', port: '2379-2380', source_ips: ['10.0.0.0/8'] },
                { direction: 'in', protocol: 'tcp', port: '10257', source_ips: ['10.0.0.0/8'] },
                { direction: 'in', protocol: 'tcp', port: '10259', source_ips: ['10.0.0.0/8'] },
                { direction: 'in', protocol: 'udp', port: '8472', source_ips: ['10.0.0.0/8'] }
              ]
            end

            rules
          end
        end
      end
    end
  end
end
