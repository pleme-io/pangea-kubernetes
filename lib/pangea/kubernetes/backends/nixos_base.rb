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

require 'pangea/kubernetes/bare_metal/cloud_init'

module Pangea
  module Kubernetes
    module Backends
      # Template method module for NixOS backends.
      # Extracts shared logic for all 4 NixOS backends (AWS, GCP, Azure, Hetzner).
      #
      # Shared methods (implemented here):
      #   - create_cluster: firewall + control plane server loop + cloud-init
      #   - create_node_pool: worker cloud-init + scaling group delegation
      #   - build_server_cloud_init: full option passthrough from config.nixos
      #   - build_agent_cloud_init: worker cloud-init with join_server
      #   - base_firewall_ports: cloud-agnostic port definitions
      #   - build_secrets_hash: extracts path references from config
      #
      # Template hooks (subclasses implement):
      #   - create_compute_instance(ctx, resource_name, config, result, cloud_init, index, tags)
      #   - create_worker_pool(ctx, name, cluster_ref, pool_config, cloud_init, tags)
      #   - create_firewall_resources(ctx, name, config, network_result, tags)
      #   - resolve_image(config)
      #   - post_create_instance(ctx, name, server, result, index, tags)
      module NixosBase
        # Kubernetes port definitions shared across all NixOS backends
        COMMON_PORTS = {
          ssh: { port: 22, protocol: :tcp, public: true, description: 'SSH' },
          http: { port: 80, protocol: :tcp, public: true, description: 'HTTP' },
          https: { port: 443, protocol: :tcp, public: true, description: 'HTTPS' },
          api: { port: 6443, protocol: :tcp, public: true, description: 'K8s API' },
          kubelet: { port: 10_250, protocol: :tcp, public: false, description: 'Kubelet' },
          etcd: { port: '2379-2380', protocol: :tcp, public: false, description: 'etcd' },
          vxlan: { port: 8472, protocol: :udp, public: false, description: 'VXLAN' },
          wireguard: { port: 51_820, protocol: :udp, public: false, description: 'WireGuard VPN' }
        }.freeze

        # Additional ports for vanilla Kubernetes
        VANILLA_K8S_PORTS = {
          controller_manager: { port: 10_257, protocol: :tcp, public: false, description: 'controller-manager' },
          scheduler: { port: 10_259, protocol: :tcp, public: false, description: 'scheduler' }
        }.freeze

        # Returns all firewall ports for the given distribution
        def base_firewall_ports(distribution)
          ports = COMMON_PORTS.dup
          ports.merge!(VANILLA_K8S_PORTS) if distribution.to_sym == :kubernetes
          ports
        end

        # Create control plane server(s) via template hooks.
        # Subclasses override create_compute_instance and create_firewall_resources.
        def nixos_create_cluster(ctx, name, config, result, tags)
          system_pool = config.system_node_pool
          cp_count = [system_pool.min_size, 1].max
          servers = []

          cp_count.times do |idx|
            cloud_init = build_server_cloud_init(name, config, idx, result)

            server = create_compute_instance(ctx, name, config, result, cloud_init, idx, tags)
            post_create_instance(ctx, name, server, result, idx, tags)

            servers << server
          end

          servers.first
        end

        # Create worker node pool via template hooks.
        # Subclasses override create_worker_pool.
        def nixos_create_node_pool(ctx, name, cluster_ref, pool_config, tags)
          cloud_init = build_agent_cloud_init(name, tags, cluster_ref)
          create_worker_pool(ctx, name, cluster_ref, pool_config, cloud_init, tags)
        end

        # Build cloud-init for a control plane server with full option passthrough.
        def build_server_cloud_init(name, config, index, result)
          gitops_config = case config.gitops_operator
                          when :fluxcd then config.fluxcd&.to_h
                          when :argocd then config.argocd&.to_h
                          end

          BareMetal::CloudInit.generate(
            cluster_name: name.to_s,
            distribution: config.distribution,
            profile: config.profile,
            distribution_track: config.distribution_track || config.kubernetes_version,
            role: 'server',
            node_index: index,
            cluster_init: index.zero?,
            network_id: result.network&.dig(:network)&.id,
            fluxcd: config.gitops_operator == :fluxcd ? gitops_config : nil,
            argocd: config.gitops_operator == :argocd ? gitops_config : nil,
            k3s: config.distribution == :k3s ? config.nixos&.k3s&.to_h : nil,
            kubernetes: config.distribution == :kubernetes ? config.nixos&.kubernetes&.to_h : nil,
            secrets: build_secrets_hash(config),
            vpn: config.vpn&.to_h,
            bootstrap_secrets: build_bootstrap_secrets(config)
          )
        end

        # Build cloud-init for a worker/agent node.
        def build_agent_cloud_init(name, tags, cluster_ref)
          track = if cluster_ref.respond_to?(:distribution_track) && cluster_ref.distribution_track
                    cluster_ref.distribution_track
                  else
                    tags[:DistributionTrack] || '1.34'
                  end

          BareMetal::CloudInit.generate(
            cluster_name: name.to_s,
            distribution: tags[:Distribution]&.to_sym || :k3s,
            profile: tags[:Profile] || 'cilium-standard',
            distribution_track: track,
            role: 'agent',
            node_index: 0,
            cluster_init: false,
            join_server: cluster_ref.ipv4_address
          )
        end

        # Extract secrets path references from config.
        # Returns nil when no secrets are configured.
        def build_secrets_hash(config)
          paths = {}

          if config.fluxcd
            paths[:flux_ssh_key_path] = config.fluxcd.source_ssh_key_file if config.fluxcd.source_ssh_key_file
            paths[:flux_token_path] = config.fluxcd.source_token_file if config.fluxcd.source_token_file
            paths[:sops_age_key_path] = config.fluxcd.sops_age_key_file if config.fluxcd.sops_age_key_file
          end

          if config.nixos&.secrets
            secrets = config.nixos.secrets
            paths[:flux_ssh_key_path] ||= secrets.flux_ssh_key_path if secrets.flux_ssh_key_path
            paths[:flux_token_path] ||= secrets.flux_token_path if secrets.flux_token_path
            paths[:sops_age_key_path] ||= secrets.sops_age_key_path if secrets.sops_age_key_path
            paths[:join_token_path] = secrets.join_token_path if secrets.join_token_path
            paths.merge!(secrets.extra_paths) if secrets.extra_paths.any?
          end

          paths.empty? ? nil : paths
        end

        # Extract bootstrap secrets from config for cloud-init delivery.
        # These are written to disk at first boot before sops-nix activates.
        # Returns nil when no bootstrap secrets are configured.
        def build_bootstrap_secrets(config)
          bs = config.bootstrap_secrets
          return nil unless bs.is_a?(Hash) && bs.any?
          return nil if bs.values.all? { |v| v.nil? || (v.is_a?(String) && v.empty?) }

          bs
        end

        # --- Template hooks (subclasses override) ---

        # Create a single compute instance. Returns a resource reference.
        def create_compute_instance(_ctx, _name, _config, _result, _cloud_init, _index, _tags)
          raise NotImplementedError, "#{self} must implement create_compute_instance"
        end

        # Create a worker pool (ASG, MIG, VMSS, or server loop). Returns a resource reference.
        def create_worker_pool(_ctx, _name, _cluster_ref, _pool_config, _cloud_init, _tags)
          raise NotImplementedError, "#{self} must implement create_worker_pool"
        end

        # Post-instance creation hook (e.g., Hetzner network attachment). No-op by default.
        def post_create_instance(_ctx, _name, _server, _result, _index, _tags)
          # no-op — subclasses override when needed
        end
      end
    end
  end
end
