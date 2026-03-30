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

module Pangea
  module Kubernetes
    # Lazy-loading backend registry. Provider gems are loaded on first use,
    # so users only need the gems for backends they actually reference.
    module BackendRegistry
      @backends = {}

      # Backend matrix: cloud x tech
      #
      # Each cloud provider can run multiple Kubernetes technologies:
      #   - Managed K8s (EKS, GKE, AKS) — cloud-native control plane
      #   - NixOS K3s — lightweight K3s on NixOS VMs via blackmatter-kubernetes
      #   - NixOS K8s — vanilla Kubernetes on NixOS VMs (future)
      #
      # Naming: {cloud}_{tech} (e.g., aws_eks, aws_nixos_k3s, gcp_gke)
      # Legacy aliases: :aws → :aws_eks, :aws_nixos → :aws_nixos_k3s
      BACKEND_MAP = {
        # ── AWS ───────────────────────────────────────────────────────
        aws_eks:        { module_path: 'pangea/kubernetes/backends/aws_eks', class_name: 'AwsEks' },
        aws_nixos_k3s:  { module_path: 'pangea/kubernetes/backends/aws_nixos', class_name: 'AwsNixos' },
        # aws_nixos_k8s: { module_path: 'pangea/kubernetes/backends/aws_nixos_k8s', class_name: 'AwsNixosK8s' },

        # ── GCP ───────────────────────────────────────────────────────
        gcp_gke:        { module_path: 'pangea/kubernetes/backends/gcp_gke', class_name: 'GcpGke' },
        gcp_nixos_k3s:  { module_path: 'pangea/kubernetes/backends/gcp_nixos', class_name: 'GcpNixos' },

        # ── Azure ─────────────────────────────────────────────────────
        azure_aks:      { module_path: 'pangea/kubernetes/backends/azure_aks', class_name: 'AzureAks' },
        azure_nixos_k3s: { module_path: 'pangea/kubernetes/backends/azure_nixos', class_name: 'AzureNixos' },

        # ── Hetzner ──────────────────────────────────────────────────
        hcloud_k3s:     { module_path: 'pangea/kubernetes/backends/hcloud_k3s', class_name: 'HcloudK3s' },
      }.freeze

      # Legacy aliases — backward compat with existing templates
      ALIASES = {
        aws:          :aws_eks,
        aws_nixos:    :aws_nixos_k3s,
        gcp:          :gcp_gke,
        gcp_nixos:    :gcp_nixos_k3s,
        azure:        :azure_aks,
        azure_nixos:  :azure_nixos_k3s,
        hcloud:       :hcloud_k3s,
      }.freeze

      class << self
        # Register a backend module for a given backend name
        def register(name, backend_module)
          @backends[name.to_sym] = backend_module
        end

        # Resolve a backend by name, lazy-loading if needed.
        # Supports both canonical names (aws_eks) and legacy aliases (aws).
        def resolve(name)
          name = name.to_sym
          # Resolve alias to canonical name
          name = ALIASES[name] if ALIASES.key?(name)

          return @backends[name] if @backends.key?(name)

          entry = BACKEND_MAP[name]
          raise ArgumentError, "Unknown backend: #{name}. Available: #{available_backends.join(', ')}" unless entry

          load_backend(name, entry)
        end

        # List all canonical backend names
        def available_backends
          BACKEND_MAP.keys
        end

        # List all names including aliases
        def all_names
          (BACKEND_MAP.keys + ALIASES.keys).uniq
        end

        # Check if a backend's provider gem is available
        def backend_available?(name)
          resolve(name)
          true
        rescue LoadError
          false
        end

        # Reset registry (for testing)
        def reset!
          @backends = {}
        end

        private

        def load_backend(name, entry)
          require entry[:module_path]
          backend_module = Pangea::Kubernetes::Backends.const_get(entry[:class_name])
          @backends[name] = backend_module
          backend_module
        end
      end
    end
  end
end
