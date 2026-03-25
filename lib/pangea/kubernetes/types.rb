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

require 'dry-struct'
require 'pangea/resources/types'
require 'pangea/kubernetes/types/firewall_config'
require 'pangea/kubernetes/types/kernel_config'
require 'pangea/kubernetes/types/wait_for_dns_config'
require 'pangea/kubernetes/types/etcd_config'
require 'pangea/kubernetes/types/pki_config'
require 'pangea/kubernetes/types/control_plane_config'
require 'pangea/kubernetes/types/secrets_config'
require 'pangea/kubernetes/types/k3s_config'
require 'pangea/kubernetes/types/kubernetes_config'
require 'pangea/kubernetes/types/argocd_config'
require 'pangea/kubernetes/types/vpn_config'

module Pangea
  module Kubernetes
    module Types
      T = Pangea::Resources::Types

      # Managed backends delegate to cloud-native K8s services (EKS, GKE, AKS)
      MANAGED_BACKENDS = %i[aws gcp azure].freeze

      # NixOS backends provision NixOS VMs with k3s/k8s via blackmatter-kubernetes
      NIXOS_BACKENDS = %i[aws_nixos gcp_nixos azure_nixos hcloud].freeze

      SUPPORTED_BACKENDS = (MANAGED_BACKENDS + NIXOS_BACKENDS).freeze

      SUPPORTED_K8S_VERSIONS = %w[
        1.27 1.28 1.29 1.30 1.31 1.32 1.33 1.34
      ].freeze

      # Distributions supported by blackmatter-kubernetes
      SUPPORTED_DISTRIBUTIONS = %i[k3s kubernetes].freeze

      # Profiles from blackmatter-kubernetes lib/profiles.nix
      SUPPORTED_PROFILES = %w[
        cloud-server
        flannel-minimal flannel-standard flannel-production
        calico-standard calico-hardened
        cilium-standard cilium-mesh
        istio-mesh
      ].freeze

      # Node pool configuration — cloud-agnostic
      class NodePoolConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :name, T::Coercible::Symbol
        attribute :instance_types, T::Array.of(T::String).constrained(min_size: 1)
        attribute :min_size, T::Coercible::Integer.constrained(gteq: 0).default(1)
        attribute :max_size, T::Coercible::Integer.constrained(gteq: 1).default(3)
        attribute :desired_size, T::Coercible::Integer.optional.default(nil)
        attribute :disk_size_gb, T::Coercible::Integer.constrained(gteq: 10).default(20)
        attribute :labels, T::Hash.default({}.freeze)
        attribute :taints, T::Array.of(T::Hash).default([].freeze)
        attribute :max_pods, T::Coercible::Integer.optional.default(nil)
        attribute :ssh_keys, T::Array.of(T::String).default([].freeze)

        def self.new(attributes)
          attrs = attributes.is_a?(::Hash) ? attributes : {}
          if attrs[:max_size] && attrs[:min_size] && attrs[:max_size] < attrs[:min_size]
            raise Dry::Struct::Error, "max_size (#{attrs[:max_size]}) must be >= min_size (#{attrs[:min_size]})"
          end
          super(attrs)
        end

        def effective_desired_size
          desired_size || min_size
        end

        def to_h
          hash = {
            name: name,
            instance_types: instance_types,
            min_size: min_size,
            max_size: max_size,
            disk_size_gb: disk_size_gb
          }
          hash[:desired_size] = desired_size if desired_size
          hash[:labels] = labels if labels.any?
          hash[:taints] = taints if taints.any?
          hash[:max_pods] = max_pods if max_pods
          hash[:ssh_keys] = ssh_keys if ssh_keys.any?
          hash
        end
      end

      # Addon configuration
      class AddonConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :name, T::Coercible::Symbol
        attribute :enabled, T::Bool.default(true)
        attribute :version, T::String.optional.default(nil)
        attribute :config, T::Hash.default({}.freeze)

        def to_h
          hash = { name: name, enabled: enabled }
          hash[:version] = version if version
          hash[:config] = config if config.any?
          hash
        end
      end

      # Network configuration — cloud-agnostic
      class NetworkConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :vpc_cidr, T::String.optional.default(nil)
        attribute :pod_cidr, T::String.optional.default(nil)
        attribute :service_cidr, T::String.optional.default(nil)
        attribute :subnet_ids, T::Array.of(T::String).default([].freeze)
        attribute :security_group_ids, T::Array.of(T::String).default([].freeze)
        attribute :private_endpoint, T::Bool.default(true)
        attribute :public_endpoint, T::Bool.default(false)

        def to_h
          hash = {
            private_endpoint: private_endpoint,
            public_endpoint: public_endpoint
          }
          hash[:vpc_cidr] = vpc_cidr if vpc_cidr
          hash[:pod_cidr] = pod_cidr if pod_cidr
          hash[:service_cidr] = service_cidr if service_cidr
          hash[:subnet_ids] = subnet_ids if subnet_ids.any?
          hash[:security_group_ids] = security_group_ids if security_group_ids.any?
          hash
        end
      end

      # FluxCD GitOps bootstrap configuration
      class FluxCDConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :enabled, T::Bool.default(true)
        attribute :source_url, T::String
        attribute :source_auth, T::String.constrained(included_in: %w[ssh token]).default('ssh')
        attribute :source_interval, T::String.default('1m0s')
        attribute :reconcile_path, T::String.default('./')
        attribute :reconcile_interval, T::String.default('2m0s')
        attribute :sops_enabled, T::Bool.default(true)

        # Git branch to track
        attribute :source_branch, T::String.default('main')

        # Enable pruning during reconciliation
        attribute :reconcile_prune, T::Bool.default(true)

        # SSH known hosts content for git source
        attribute :known_hosts, T::String.optional.default(nil)

        # Path to SSH key file (sops-nix decrypted path on NixOS)
        attribute :source_ssh_key_file, T::String.optional.default(nil)

        # Path to token file (sops-nix decrypted path on NixOS)
        attribute :source_token_file, T::String.optional.default(nil)

        # Username for token-based auth
        attribute :source_token_username, T::String.default('git')

        # Path to SOPS age key file (sops-nix decrypted path on NixOS)
        attribute :sops_age_key_file, T::String.optional.default(nil)

        def to_h
          hash = {
            enabled: enabled,
            source_url: source_url,
            source_auth: source_auth,
            source_interval: source_interval,
            reconcile_path: reconcile_path,
            reconcile_interval: reconcile_interval,
            sops_enabled: sops_enabled,
            source_branch: source_branch,
            reconcile_prune: reconcile_prune,
            source_token_username: source_token_username
          }
          hash[:known_hosts] = known_hosts if known_hosts
          hash[:source_ssh_key_file] = source_ssh_key_file if source_ssh_key_file
          hash[:source_token_file] = source_token_file if source_token_file
          hash[:sops_age_key_file] = sops_age_key_file if sops_age_key_file
          hash
        end
      end

      # NixOS-specific configuration for blackmatter-kubernetes modules
      class NixOSConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :image_id, T::String.optional.default(nil)
        attribute :flake_url, T::String.optional.default(nil)
        attribute :extra_modules, T::Array.of(T::String).default([].freeze)
        attribute :sops_age_key_secret, T::String.optional.default(nil)
        attribute :flux_ssh_key_secret, T::String.optional.default(nil)

        # K3s distribution options (when distribution == :k3s)
        attribute :k3s, K3sConfig.optional.default(nil)

        # Vanilla Kubernetes distribution options (when distribution == :kubernetes)
        attribute :kubernetes, VanillaKubernetesConfig.optional.default(nil)

        # Secrets configuration (sops-nix path references)
        attribute :secrets, SecretsConfig.optional.default(nil)

        def to_h
          hash = {}
          hash[:image_id] = image_id if image_id
          hash[:flake_url] = flake_url if flake_url
          hash[:extra_modules] = extra_modules if extra_modules.any?
          hash[:sops_age_key_secret] = sops_age_key_secret if sops_age_key_secret
          hash[:flux_ssh_key_secret] = flux_ssh_key_secret if flux_ssh_key_secret
          hash[:k3s] = k3s.to_h if k3s
          hash[:kubernetes] = kubernetes.to_h if kubernetes
          hash[:secrets] = secrets.to_h if secrets
          hash
        end
      end

      # Cluster-level configuration — cloud-agnostic
      class ClusterConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :backend, T::Coercible::Symbol.constrained(included_in: SUPPORTED_BACKENDS)
        attribute :kubernetes_version, T::String.constrained(included_in: SUPPORTED_K8S_VERSIONS).default('1.29')
        attribute :region, T::String
        attribute :node_pools, T::Array.of(NodePoolConfig).constrained(min_size: 1)
        attribute :network, NetworkConfig.optional.default(nil)
        attribute :addons, T::Array.of(T::Coercible::Symbol).default([].freeze)
        attribute :tags, T::Hash.default({}.freeze)
        attribute :encryption_at_rest, T::Bool.default(true)
        attribute :logging, T::Array.of(T::String).default([].freeze)

        # Distribution: k3s or vanilla kubernetes (NixOS backends only)
        attribute :distribution, T::Coercible::Symbol.constrained(
          included_in: SUPPORTED_DISTRIBUTIONS
        ).default(:k3s)

        # Blackmatter-kubernetes profile (NixOS backends only)
        attribute :profile, T::String.constrained(
          included_in: SUPPORTED_PROFILES
        ).default('cloud-server')

        # Distribution version track (e.g., '1.34', '1.35')
        attribute :distribution_track, T::String.optional.default(nil)

        # GitOps operator selection (:fluxcd or :argocd, default: :fluxcd)
        attribute :gitops_operator, T::Coercible::Symbol.constrained(
          included_in: %i[fluxcd argocd none]
        ).default(:fluxcd)

        # FluxCD GitOps bootstrap (NixOS backends only)
        attribute :fluxcd, FluxCDConfig.optional.default(nil)

        # ArgoCD GitOps bootstrap (NixOS backends only)
        attribute :argocd, ArgocdConfig.optional.default(nil)

        # Enable Karpenter IRSA IAM role at Terraform time (AWS only).
        # Karpenter itself is deployed post-cluster via GitOps.
        attribute :karpenter_enabled, T::Bool.default(false)

        # Enable etcd backup S3 bucket creation (AWS only).
        # Default off for cost savings. Production profiles should enable.
        attribute :etcd_backup_enabled, T::Bool.default(false)

        # Enable S3 versioning on the etcd backup bucket.
        # Default off for cost savings. Production should keep this on.
        attribute :etcd_backup_versioning, T::Bool.default(false)

        # ── Load Balancing ─────────────────────────────────────────
        # ALB for HTTP/HTTPS ingress traffic (public → web tier nodes)
        attribute :ingress_alb_enabled, T::Bool.default(false)
        attribute :ingress_alb_certificate_arn, T::String.optional.default(nil)
        attribute :ingress_alb_idle_timeout, (T::Coercible::Integer | T::Coercible::Float).default(60)
        attribute :ingress_alb_http_redirect, T::Bool.default(true)

        # VPN NLB for WireGuard operator access (public, UDP)
        attribute :vpn_nlb_enabled, T::Bool.default(false)
        attribute :vpn_nlb_port, (T::Coercible::Integer | T::Coercible::Float).default(51822)

        # Internal K8s API NLB is always created (required for worker join)

        # ── Security Hardening ────────────────────────────────────────

        # Restrict node SG HTTP/HTTPS to ALB SG source (not 0.0.0.0/0).
        # Only effective when ingress_alb_enabled is also true.
        # Default on — when ALB exists, nodes should only accept traffic from it.
        attribute :sg_restrict_http_to_alb, T::Bool.default(true)

        # Source CIDR for WireGuard VPN NLB ingress (internet-facing).
        # nil = 0.0.0.0/0 (current default). Set to operator IP range for hardening.
        attribute :vpn_source_cidr, T::String.optional.default(nil)

        # Enable VPC flow logs for network traffic auditing.
        attribute :flow_logs_enabled, T::Bool.default(false)
        attribute :flow_logs_traffic_type, T::String.constrained(
          included_in: %w[ALL ACCEPT REJECT]
        ).default('ALL')
        attribute :flow_logs_retention_days, (T::Coercible::Integer | T::Coercible::Float).default(30)

        # Enable KMS encryption for CloudWatch log groups.
        # When true + kms_key_arn nil → creates a new KMS key with rotation.
        attribute :kms_logs_enabled, T::Bool.default(false)
        attribute :kms_key_arn, T::String.optional.default(nil)

        # Create one NAT gateway per AZ (HA). false = single NAT in public-a.
        attribute :nat_per_az, T::Bool.default(false)

        # SSM-only access: no SSH key pair, no port 22 SG rule.
        attribute :ssm_only, T::Bool.default(false)

        # Separate S3 bucket for SSM session logs (nil = reuse etcd backup bucket).
        attribute :ssm_logs_bucket, T::String.optional.default(nil)

        # VPN target group health check (default: match vpn_nlb_port, not SSH 22).
        attribute :vpn_health_check_port, (T::Coercible::Integer | T::Coercible::Float).optional.default(nil)

        # Source CIDR for all internet-facing ingress (ALB, node HTTP/HTTPS).
        # nil = 0.0.0.0/0 (open). Set to operator IP/32 to lock down the entire perimeter.
        attribute :ingress_source_cidr, T::String.optional.default(nil)

        # ACM certificate domain for ALB HTTPS (creates cert when set + no certificate_arn).
        attribute :ingress_alb_domain, T::String.optional.default(nil)
        attribute :ingress_alb_zone_id, T::String.optional.default(nil)

        # Bootstrap secrets delivered via cloud-init for first-boot trust chain.
        # Written to disk before sops-nix activates. Never included in resource tags.
        # Keys: sops_age_key (cluster age private key), flux_github_token (GitHub PAT)
        attribute :bootstrap_secrets, T::Hash.default({}.freeze)

        # NixOS configuration (NixOS backends only)
        attribute :nixos, NixOSConfig.optional.default(nil)

        # VPN configuration (WireGuard links for operator access)
        attribute :vpn, VpnConfig.optional.default(nil)

        # ── Infrastructure parameters (NOT tags — typed config fields) ──
        # These were previously smuggled through the tags hash.
        # Now they're proper typed attributes that don't pollute resource tags.

        # AWS account ID for IAM policy scoping (12-digit string)
        attribute :account_id, T::String.optional.default(nil)

        # S3 bucket name for etcd backups (when etcd_backup_enabled)
        attribute :etcd_backup_bucket, T::String.optional.default(nil)

        # CIDR for SSH access restriction (e.g., '10.0.0.0/8')
        attribute :ssh_cidr, T::String.default('10.0.0.0/8')

        # CIDR for K8s API access restriction
        attribute :api_cidr, T::String.default('10.0.0.0/8')

        # VPN CIDR for WireGuard tunnel (e.g., '10.100.3.0/24')
        attribute :vpn_cidr, T::String.optional.default(nil)

        # AWS-specific (managed EKS or NixOS EC2)
        attribute :role_arn, T::String.optional.default(nil)
        attribute :ami_id, T::String.optional.default(nil)
        attribute :key_pair, T::String.optional.default(nil)

        # GCP-specific (managed GKE or NixOS GCE)
        attribute :project, T::String.optional.default(nil)
        attribute :gce_image, T::String.optional.default(nil)

        # Azure-specific (managed AKS or NixOS VMs)
        attribute :resource_group_name, T::String.optional.default(nil)
        attribute :dns_prefix, T::String.optional.default(nil)
        attribute :azure_image_id, T::String.optional.default(nil)

        def managed_kubernetes?
          MANAGED_BACKENDS.include?(backend)
        end

        def nixos_backend?
          NIXOS_BACKENDS.include?(backend)
        end

        def system_node_pool
          node_pools.find { |np| np.name == :system } || node_pools.first
        end

        def worker_node_pools
          node_pools.reject { |np| np.name == :system }
        end

        def self.new(attributes)
          instance = super
          instance.vpn&.validate! if instance.vpn
          instance
        end

        def to_h
          hash = {
            backend: backend,
            kubernetes_version: kubernetes_version,
            region: region,
            node_pools: node_pools.map(&:to_h)
          }
          hash[:network] = network.to_h if network
          hash[:addons] = addons if addons.any?
          hash[:tags] = tags if tags.any?
          hash[:encryption_at_rest] = encryption_at_rest
          hash[:logging] = logging if logging.any?
          hash[:distribution] = distribution
          hash[:profile] = profile
          hash[:distribution_track] = distribution_track if distribution_track
          hash[:fluxcd] = fluxcd.to_h if fluxcd
          hash[:nixos] = nixos.to_h if nixos
          hash[:vpn] = vpn.to_h if vpn && vpn.links.any?
          hash[:role_arn] = role_arn if role_arn
          hash[:ami_id] = ami_id if ami_id
          hash[:key_pair] = key_pair if key_pair
          hash[:project] = project if project
          hash[:gce_image] = gce_image if gce_image
          hash[:resource_group_name] = resource_group_name if resource_group_name
          hash[:dns_prefix] = dns_prefix if dns_prefix
          hash[:azure_image_id] = azure_image_id if azure_image_id
          hash
        end
      end

      # Deployment context — metadata for the architecture reference
      class DeploymentContext < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :environment, T::Coercible::Symbol.constrained(included_in: %i[production staging development])
        attribute :cluster_name, T::Coercible::Symbol
        attribute :team, T::String.optional.default(nil)
        attribute :cost_center, T::String.optional.default(nil)

        def to_h
          hash = { environment: environment, cluster_name: cluster_name }
          hash[:team] = team if team
          hash[:cost_center] = cost_center if cost_center
          hash
        end
      end

      # Load balancer configuration for elastic LB tier
      class LoadBalancerConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :mode, T::String.constrained(included_in: %w[haproxy haproxy-bird]).default('haproxy')
        attribute :instance_count, T::Coercible::Integer.constrained(gteq: 1).default(2)
        attribute :instance_type, T::String
        attribute :region, T::String
        attribute :backends, T::Array.of(T::Hash).constrained(min_size: 1)
        attribute :health_check_interval, T::String.default('5s')
        attribute :max_connections, T::Coercible::Integer.default(50_000)
        attribute :frontend_ports, T::Array.of(T::Coercible::Integer).default([80, 443].freeze)
        attribute :tags, T::Hash.default({}.freeze)

        # Bare metal BGP options
        attribute :bgp_asn, T::Coercible::Integer.optional.default(nil)
        attribute :bgp_neighbor, T::String.optional.default(nil)
        attribute :vrrp_interface, T::String.optional.default(nil)
        attribute :virtual_ips, T::Array.of(T::String).default([].freeze)

        def bare_metal?
          mode == 'haproxy-bird'
        end

        def to_h
          hash = {
            mode: mode,
            instance_count: instance_count,
            instance_type: instance_type,
            region: region,
            backends: backends,
            health_check_interval: health_check_interval,
            max_connections: max_connections,
            frontend_ports: frontend_ports
          }
          hash[:tags] = tags if tags.any?
          hash[:bgp_asn] = bgp_asn if bgp_asn
          hash[:bgp_neighbor] = bgp_neighbor if bgp_neighbor
          hash[:vrrp_interface] = vrrp_interface if vrrp_interface
          hash[:virtual_ips] = virtual_ips if virtual_ips.any?
          hash
        end
      end
    end
  end
end
