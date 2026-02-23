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
      # GCP GKE backend — creates managed GKE clusters with VPC-native networking.
      module GcpGke
        include Base

        class << self
          def backend_name = :gcp
          def managed_kubernetes? = true
          def required_gem = 'pangea-gcp'

          def load_provider!
            require required_gem
          rescue LoadError => e
            raise LoadError,
                  "Backend :gcp requires gem 'pangea-gcp'. " \
                  "Add it to your Gemfile: gem 'pangea-gcp'\n" \
                  "Original error: #{e.message}"
          end

          # Create GCP VPC network + subnet
          def create_network(ctx, name, config, tags)
            network = {}

            network[:vpc] = ctx.google_compute_network(
              :"#{name}_network",
              name: "#{name}-network",
              auto_create_subnetworks: false,
              project: config.project
            )

            network[:subnet] = ctx.google_compute_subnetwork(
              :"#{name}_subnet",
              name: "#{name}-subnet",
              ip_cidr_range: config.network&.vpc_cidr || '10.0.0.0/20',
              region: config.region,
              network: network[:vpc].id,
              project: config.project,
              secondary_ip_range: [
                { range_name: "#{name}-pods", ip_cidr_range: config.network&.pod_cidr || '10.1.0.0/16' },
                { range_name: "#{name}-services", ip_cidr_range: config.network&.service_cidr || '10.2.0.0/20' }
              ]
            )

            network
          end

          # GKE uses Workload Identity — no standalone IAM resources needed
          def create_iam(ctx, name, config, tags)
            iam = {}

            # Service account for GKE nodes
            iam[:node_sa] = ctx.google_service_account(
              :"#{name}_node_sa",
              account_id: "#{name}-gke-nodes",
              display_name: "#{name} GKE Node Service Account",
              project: config.project
            )

            # Bind minimum required roles
            %w[logging.logWriter monitoring.metricWriter monitoring.viewer].each do |role|
              ctx.google_project_iam_member(
                :"#{name}_node_#{role.gsub('.', '_')}",
                project: config.project,
                role: "roles/#{role}",
                member: "serviceAccount:#{iam[:node_sa].email}"
              )
            end

            iam
          end

          # Create the GKE cluster
          def create_cluster(ctx, name, config, result, tags)
            cluster_attrs = {
              name: "#{name}-cluster",
              location: config.region,
              project: config.project,
              initial_node_count: 1,
              remove_default_node_pool: true,
              min_master_version: config.kubernetes_version,
              deletion_protection: false,
              networking_mode: 'VPC_NATIVE',
              resource_labels: gke_labels(tags)
            }

            # VPC-native networking
            if result.network
              cluster_attrs[:network] = result.network[:vpc]&.id
              cluster_attrs[:subnetwork] = result.network[:subnet]&.id
              cluster_attrs[:ip_allocation_policy] = {
                cluster_secondary_range_name: "#{name}-pods",
                services_secondary_range_name: "#{name}-services"
              }
            end

            # Private cluster
            if config.network&.private_endpoint
              cluster_attrs[:private_cluster_config] = {
                enable_private_nodes: true,
                enable_private_endpoint: !config.network.public_endpoint,
                master_ipv4_cidr_block: '172.16.0.0/28'
              }
            end

            # Workload Identity
            if config.project
              cluster_attrs[:workload_identity_config] = {
                workload_pool: "#{config.project}.svc.id.goog"
              }
            end

            # Release channel
            cluster_attrs[:release_channel] = { channel: 'REGULAR' }

            ctx.google_container_cluster(:"#{name}_cluster", cluster_attrs)
          end

          # Create a GKE node pool
          def create_node_pool(ctx, name, cluster_ref, pool_config, tags)
            pool_name = :"#{name}_#{pool_config.name}"

            node_pool_attrs = {
              name: "#{name}-#{pool_config.name}",
              cluster: cluster_ref.id,
              location: tags[:Region] || 'us-central1',
              initial_node_count: pool_config.effective_desired_size,
              node_config: {
                machine_type: pool_config.instance_types.first,
                disk_size_gb: pool_config.disk_size_gb,
                oauth_scopes: ['https://www.googleapis.com/auth/cloud-platform'],
                labels: pool_config.labels.merge(
                  'node-pool' => pool_config.name.to_s
                )
              },
              autoscaling: {
                min_node_count: pool_config.min_size,
                max_node_count: pool_config.max_size
              }
            }

            ctx.google_container_node_pool(pool_name, node_pool_attrs)
          end

          private

          # Convert tags to GKE-compatible labels (lowercase, hyphens)
          def gke_labels(tags)
            tags.transform_keys { |k| k.to_s.downcase.gsub(/[^a-z0-9-]/, '-') }
              .transform_values { |v| v.to_s.downcase.gsub(/[^a-z0-9-]/, '-') }
          end
        end
      end
    end
  end
end
