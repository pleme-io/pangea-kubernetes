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

      BACKEND_MAP = {
        # Managed K8s backends (delegate to cloud-native services)
        aws: { module_path: 'pangea/kubernetes/backends/aws_eks', class_name: 'AwsEks' },
        gcp: { module_path: 'pangea/kubernetes/backends/gcp_gke', class_name: 'GcpGke' },
        azure: { module_path: 'pangea/kubernetes/backends/azure_aks', class_name: 'AzureAks' },

        # NixOS backends (k3s/k8s on NixOS VMs via blackmatter-kubernetes)
        aws_nixos: { module_path: 'pangea/kubernetes/backends/aws_nixos', class_name: 'AwsNixos' },
        gcp_nixos: { module_path: 'pangea/kubernetes/backends/gcp_nixos', class_name: 'GcpNixos' },
        azure_nixos: { module_path: 'pangea/kubernetes/backends/azure_nixos', class_name: 'AzureNixos' },
        hcloud: { module_path: 'pangea/kubernetes/backends/hcloud_k3s', class_name: 'HcloudK3s' }
      }.freeze

      class << self
        # Register a backend module for a given backend name
        def register(name, backend_module)
          @backends[name.to_sym] = backend_module
        end

        # Resolve a backend by name, lazy-loading if needed
        def resolve(name)
          name = name.to_sym
          return @backends[name] if @backends.key?(name)

          entry = BACKEND_MAP[name]
          raise ArgumentError, "Unknown backend: #{name}. Available: #{available_backends.join(', ')}" unless entry

          load_backend(name, entry)
        end

        # List all registered + available backends
        def available_backends
          BACKEND_MAP.keys
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
