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

require 'json'

module Pangea
  module Kubernetes
    module BareMetal
      # Generates cloud-init user_data for NixOS servers running k3s or vanilla Kubernetes
      # via blackmatter-kubernetes modules.
      #
      # The NixOS boot sequence reads /etc/pangea/cluster-config.json and applies
      # the corresponding blackmatter-kubernetes module (k3s or kubernetes).
      #
      # Config is cloud-agnostic — the same JSON drives k3s/k8s setup on
      # AWS EC2, GCP GCE, Azure VMs, and Hetzner servers.
      module CloudInit
        class << self
          # Generate cloud-init YAML for a NixOS Kubernetes node.
          #
          # @param cluster_name [String] Name of the cluster
          # @param distribution [Symbol] :k3s or :kubernetes
          # @param profile [String] blackmatter-kubernetes profile (e.g., 'cilium-standard')
          # @param distribution_track [String] version track (e.g., '1.34')
          # @param role [String] 'server'/'agent' (k3s) or 'control-plane'/'worker' (k8s)
          # @param node_index [Integer] Index within the role group
          # @param cluster_init [Boolean] Whether this is the first server (cluster-init)
          # @param network_id [String, nil] Cloud network ID for private networking
          # @param join_server [String, nil] IP/hostname of the server to join
          # @param fluxcd [Hash, nil] FluxCD bootstrap configuration
          # @param argocd [Hash, nil] ArgoCD bootstrap configuration
          # @param k3s [Hash, nil] K3s distribution options (full passthrough)
          # @param kubernetes [Hash, nil] Vanilla Kubernetes options (full passthrough)
          # @param secrets [Hash, nil] Secrets path references (sops-nix)
          # @param vpn [Hash, nil] VPN configuration (WireGuard links)
          # @return [String] cloud-init YAML
          def generate(cluster_name:, distribution: :k3s, profile: 'cilium-standard',
                       distribution_track: '1.34', role: 'server', node_index: 0,
                       cluster_init: false, network_id: nil, join_server: nil,
                       fluxcd: nil, argocd: nil, k3s: nil, kubernetes: nil, secrets: nil,
                       vpn: nil)
            config = {
              'cluster_name' => cluster_name,
              'distribution' => distribution.to_s,
              'profile' => profile,
              'distribution_track' => distribution_track,
              'role' => normalize_role(distribution, role),
              'node_index' => node_index,
              'cluster_init' => cluster_init
            }

            config['network_id'] = network_id if network_id
            config['join_server'] = join_server if join_server
            config['fluxcd'] = fluxcd if fluxcd
            config['argocd'] = stringify_keys_recursive(argocd) if argocd && !argocd.empty?
            config['k3s'] = stringify_keys_recursive(k3s) if k3s && !k3s.empty?
            config['kubernetes'] = stringify_keys_recursive(kubernetes) if kubernetes && !kubernetes.empty?
            config['secrets'] = stringify_keys_recursive(secrets) if secrets && !secrets.empty?
            config['vpn'] = stringify_keys_recursive(vpn) if vpn && !vpn.empty?

            generate_cloud_init_yaml(config, distribution)
          end

          private

          # Normalize role names across distributions:
          # k3s: server/agent
          # kubernetes: control-plane/worker
          def normalize_role(distribution, role)
            return role if distribution.to_sym == :k3s

            case role.to_s
            when 'server' then 'control-plane'
            when 'agent' then 'worker'
            else role.to_s
            end
          end

          def bootstrap_service(_distribution)
            'kindling-server-bootstrap'
          end

          def config_path
            '/etc/pangea/cluster-config.json'
          end

          # Recursively convert symbol keys to strings for JSON serialization
          def stringify_keys_recursive(obj)
            case obj
            when Hash
              obj.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_keys_recursive(v) }
            when Array
              obj.map { |v| stringify_keys_recursive(v) }
            else
              obj
            end
          end

          def generate_cloud_init_yaml(config, distribution)
            <<~YAML
              #cloud-config
              write_files:
                - path: #{config_path}
                  content: '#{config.to_json}'
                  permissions: '0640'
              runcmd:
                - ['systemctl', 'start', '#{bootstrap_service(distribution)}']
            YAML
          end
        end
      end
    end
  end
end
