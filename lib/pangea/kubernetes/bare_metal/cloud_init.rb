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
      # Generates user_data for NixOS servers running k3s or vanilla Kubernetes
      # via blackmatter-kubernetes modules.
      #
      # The NixOS boot sequence reads /etc/pangea/cluster-config.json and applies
      # the corresponding blackmatter-kubernetes module (k3s or kubernetes).
      #
      # Config is cloud-agnostic — the same JSON drives k3s/k8s setup on
      # AWS EC2, GCP GCE, Azure VMs, and Hetzner servers.
      #
      # Two output formats:
      #   :shell        — bash script (NixOS AMIs with amazon-init, default)
      #   :cloud_config — #cloud-config YAML (providers with real cloud-init)
      module CloudInit
        class << self
          # Generate user_data for a NixOS Kubernetes node.
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
          # @param bootstrap_secrets [Hash, nil] Bootstrap secrets (age key, tokens) written at first boot
          # @param format [Symbol] :shell (NixOS AMIs) or :cloud_config (real cloud-init)
          # @return [String] user_data string
          def generate(cluster_name:, distribution: :k3s, profile: 'cloud-server',
                       distribution_track: '1.34', role: 'server', node_index: 0,
                       cluster_init: false, network_id: nil, join_server: nil,
                       fluxcd: nil, argocd: nil, k3s: nil, kubernetes: nil, secrets: nil,
                       vpn: nil, bootstrap_secrets: nil, format: :shell)
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
            config['bootstrap_secrets'] = stringify_keys_recursive(bootstrap_secrets) if bootstrap_secrets && !bootstrap_secrets.empty?

            case format.to_sym
            when :cloud_config
              generate_cloud_config(config)
            else
              generate_shell_script(config)
            end
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

          # Shell script format — for NixOS AMIs with amazon-init.
          # amazon-init executes user_data as a shell script directly.
          #
          # The script ONLY writes the cluster config JSON. The pre-installed
          # kindling-server-bootstrap.service (baked into the AMI) detects the
          # file via ExecCondition and runs the 13-phase bootstrap automatically.
          # This avoids a slow `nix run` that would re-download/build kindling.
          #
          # When node_index is "dynamic", the script queries EC2 instance
          # metadata to derive a unique index from the instance ID. This is
          # needed for ASG-based workers where all instances share the same
          # launch template and cannot have a Terraform-time unique index.
          def generate_shell_script(config)
            dynamic_index = config['node_index'] == 'dynamic'
            json = config.to_json
            <<~SHELL
              #!/usr/bin/env bash
              set -euo pipefail
              #{dynamic_index_snippet if dynamic_index}
              mkdir -p "$(dirname '#{config_path}')"
              cat > '#{config_path}' << 'PANGEA_CONFIG_EOF'
              #{json}
              PANGEA_CONFIG_EOF
              #{dynamic_index_sed_snippet if dynamic_index}
              chmod 0640 '#{config_path}'
            SHELL
          end

          # Shell snippet that resolves a unique node index from EC2 instance
          # metadata. Uses the last 8 hex digits of the instance ID, converted
          # to decimal, modulo 10000 for a reasonable hostname suffix.
          def dynamic_index_snippet
            # Uses double-quoted heredoc so Ruby does NOT interpolate (no #{} used),
            # but shell WILL expand ${} at runtime.
            <<~'BASH'.chomp
              # Resolve dynamic node_index from EC2 instance metadata (IMDSv2)
              IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
                -H "X-aws-ec2-metadata-token-ttl-seconds: 30" 2>/dev/null || true)
              INSTANCE_ID=$(curl -sf -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
                "http://169.254.169.254/latest/meta-data/instance-id" 2>/dev/null || echo "i-unknown0000")
              # Extract last 8 hex chars, convert to decimal mod 10000
              HEX_SUFFIX="${INSTANCE_ID: -8}"
              NODE_INDEX=$(( 16#${HEX_SUFFIX} % 10000 ))
            BASH
          end

          # Shell snippet that replaces the "dynamic" sentinel in the config JSON
          # with the resolved NODE_INDEX value. Uses Ruby interpolation for the
          # config path, but shell interpolation for NODE_INDEX.
          def dynamic_index_sed_snippet
            # rubocop:disable Style/StringLiterals
            "# Replace dynamic node_index sentinel with resolved value\n" \
            "sed -i \"s/\\\"node_index\\\":\\\"dynamic\\\"/\\\"node_index\\\":${NODE_INDEX}/\" '#{config_path}'"
            # rubocop:enable Style/StringLiterals
          end

          # cloud-config YAML format — for providers with real cloud-init
          # (Hetzner, GCP, Azure, etc.).
          #
          # Only writes the config file. The pre-installed kindling-server-bootstrap
          # service handles the actual bootstrap after cloud-init completes.
          def generate_cloud_config(config)
            <<~YAML
              #cloud-config
              write_files:
                - path: #{config_path}
                  content: '#{config.to_json}'
                  permissions: '0640'
            YAML
          end
        end
      end
    end
  end
end
