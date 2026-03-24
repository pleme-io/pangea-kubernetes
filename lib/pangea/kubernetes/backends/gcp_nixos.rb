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
      # GCP NixOS backend — GCE instances running NixOS with k3s/k8s
      # via blackmatter-kubernetes modules.
      #
      # Uses:
      #   - GCE instances for control plane (static)
      #   - Managed Instance Groups (MIGs) for worker node pools
      #   - VPC + Firewall rules for networking
      #   - Instance Templates for NixOS image + cloud-init
      #
      # No managed K8s services (GKE) — all k3s/k8s managed by NixOS.
      module GcpNixos
        include Base
        extend NixosBase

        class << self
          def backend_name = :gcp_nixos
          def managed_kubernetes? = false
          def required_gem = 'pangea-gcp'

          def load_provider!
            require required_gem
          rescue LoadError => e
            raise LoadError,
                  "Backend :gcp_nixos requires gem 'pangea-gcp'. " \
                  "Add it to your Gemfile: gem 'pangea-gcp'\n" \
                  "Original error: #{e.message}"
          end

          # Create VPC network + subnet + firewall rules
          def create_network(ctx, name, config, tags)
            network = Architecture::GcpNetworkResult.new

            network.vpc = ctx.google_compute_network(
              :"#{name}_network",
              name: "#{name}-network",
              auto_create_subnetworks: false,
              project: config.project
            )

            subnet = ctx.google_compute_subnetwork(
              :"#{name}_subnet",
              name: "#{name}-subnet",
              ip_cidr_range: config.network&.vpc_cidr || '10.0.0.0/20',
              region: config.region,
              network: network.vpc.id,
              project: config.project
            )
            network.add_subnet(:subnet, subnet)

            # Firewall rules for k3s/k8s
            network.firewall_internal = ctx.google_compute_firewall(
              :"#{name}_fw_internal",
              name: "#{name}-allow-internal",
              network: network.vpc.id,
              project: config.project,
              allow: [
                { protocol: 'tcp', ports: %w[0-65535] },
                { protocol: 'udp', ports: %w[0-65535] },
                { protocol: 'icmp' }
              ],
              source_ranges: [config.network&.vpc_cidr || '10.0.0.0/20']
            )

            network.firewall_external = ctx.google_compute_firewall(
              :"#{name}_fw_external",
              name: "#{name}-allow-external",
              network: network.vpc.id,
              project: config.project,
              allow: [
                { protocol: 'tcp', ports: %w[22 80 443 6443] }
              ],
              source_ranges: ['0.0.0.0/0']
            )

            network
          end

          # Service account for GCE instances (minimal permissions)
          def create_iam(ctx, name, config, tags)
            iam = Architecture::GcpIamResult.new

            iam.node_sa = ctx.google_service_account(
              :"#{name}_node_sa",
              account_id: "#{name}-nixos-nodes",
              display_name: "#{name} NixOS K8s Node Service Account",
              project: config.project
            )

            %w[logging.logWriter monitoring.metricWriter].each do |role|
              ctx.google_project_iam_member(
                :"#{name}_node_#{role.gsub('.', '_')}",
                project: config.project,
                role: "roles/#{role}",
                member: "serviceAccount:#{iam.node_sa.email}"
              )
            end

            iam
          end

          # Create control plane GCE instances (static, no MIG)
          def create_cluster(ctx, name, config, result, tags)
            nixos_create_cluster(ctx, name, config, result, tags)
          end

          # Create worker node pool via Instance Template + MIG + Autoscaler
          def create_node_pool(ctx, name, cluster_ref, pool_config, tags)
            nixos_create_node_pool(ctx, name, cluster_ref, pool_config, tags)
          end

          # --- NixosBase template hooks ---

          def create_compute_instance(ctx, name, config, result, cloud_init, index, tags)
            system_pool = config.system_node_pool
            machine_type = system_pool.instance_types.first
            image = config.gce_image || config.nixos&.image_id || 'nixos-24-05'

            ctx.google_compute_instance(
              :"#{name}_cp_#{index}",
              name: "#{name}-cp-#{index}",
              machine_type: machine_type,
              zone: "#{config.region}-a",
              project: config.project,
              boot_disk: {
                initialize_params: {
                  image: image,
                  size: system_pool.disk_size_gb
                }
              },
              network_interface: {
                network: result.network&.dig(:vpc)&.id,
                subnetwork: result.network&.dig(:subnet)&.id,
                access_config: {}
              },
              metadata: {
                'user-data' => cloud_init
              },
              service_account: {
                email: result.iam&.dig(:node_sa)&.email,
                scopes: ['cloud-platform']
              },
              labels: gce_labels(tags.merge(
                role: 'control-plane',
                node_index: index.to_s,
                distribution: config.distribution.to_s
              ))
            )
          end

          def create_worker_pool(ctx, name, _cluster_ref, pool_config, cloud_init, tags)
            pool_name = :"#{name}_#{pool_config.name}"
            machine_type = pool_config.instance_types.first

            # Instance Template
            template = ctx.google_compute_instance_template(
              :"#{pool_name}_template",
              name: "#{name}-#{pool_config.name}-template",
              machine_type: machine_type,
              project: tags[:Project],
              disk: [{
                source_image: tags[:Image] || 'nixos-24-05',
                disk_size_gb: pool_config.disk_size_gb,
                auto_delete: true,
                boot: true
              }],
              network_interface: {
                network: tags[:NetworkId],
                subnetwork: tags[:SubnetId],
                access_config: {}
              },
              metadata: { 'user-data' => cloud_init },
              labels: gce_labels(tags.merge(
                role: 'worker',
                node_pool: pool_config.name.to_s
              ))
            )

            # Managed Instance Group
            mig = ctx.google_compute_instance_group_manager(
              :"#{pool_name}_mig",
              name: "#{name}-#{pool_config.name}-mig",
              base_instance_name: "#{name}-#{pool_config.name}",
              zone: "#{tags[:Region] || 'us-central1'}-a",
              project: tags[:Project],
              target_size: pool_config.effective_desired_size,
              version: [{
                instance_template: template.id
              }]
            )

            # Autoscaler
            ctx.google_compute_autoscaler(
              :"#{pool_name}_autoscaler",
              name: "#{name}-#{pool_config.name}-autoscaler",
              zone: "#{tags[:Region] || 'us-central1'}-a",
              project: tags[:Project],
              target: mig.id,
              autoscaling_policy: {
                min_replicas: pool_config.min_size,
                max_replicas: pool_config.max_size,
                cpu_utilization: { target: 0.7 }
              }
            )

            mig
          end

          private

          def gce_labels(tags)
            tags.transform_keys { |k| k.to_s.downcase.gsub(/[^a-z0-9-]/, '-') }
              .transform_values { |v| v.to_s.downcase.gsub(/[^a-z0-9-]/, '-') }
          end
        end
      end
    end
  end
end
