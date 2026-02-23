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

require 'pangea/kubernetes/types'
require 'pangea/kubernetes/backend_registry'
require 'pangea/kubernetes/backends/base'

module Pangea
  module Kubernetes
    # Cloud-agnostic Kubernetes architecture module.
    # Provides kubernetes_cluster() and kubernetes_node_pool() functions
    # that delegate to provider-specific backends.
    #
    # This module is designed to be included in a synthesizer context
    # (AbstractSynthesizer or TerraformSynthesizer).
    #
    # @example
    #   class MyInfra < TerraformSynthesizer
    #     include Pangea::Kubernetes::Architecture
    #
    #     def build
    #       kubernetes_cluster(:production, {
    #         backend: :aws,
    #         kubernetes_version: '1.29',
    #         region: 'us-east-1',
    #         node_pools: [
    #           { name: :system, instance_types: ['t3.large'], min_size: 2, max_size: 5 }
    #         ]
    #       })
    #     end
    #   end
    module Architecture
      # Create a complete Kubernetes cluster with all supporting infrastructure.
      #
      # Phase pipeline: Network → IAM → Cluster → Node Pools → Addons
      #
      # @param name [Symbol] Architecture name
      # @param attributes [Hash] Cluster configuration (see Types::ClusterConfig)
      # @return [ArchitectureResult] with cluster, node_pools, network, iam references
      def kubernetes_cluster(name, attributes = {})
        config = Types::ClusterConfig.new(attributes)
        backend_module = BackendRegistry.resolve(config.backend)
        backend_module.load_provider!

        base_tags = {
          KubernetesCluster: name.to_s,
          Backend: config.backend.to_s,
          ManagedBy: 'Pangea'
        }.merge(config.tags)

        result = ArchitectureResult.new(name, config)

        # Phase 1: Network
        if config.network
          result.network = backend_module.create_network(self, name, config, base_tags)
        end

        # Phase 2: IAM
        result.iam = backend_module.create_iam(self, name, config, base_tags)

        # Phase 3: Cluster
        result.cluster = backend_module.create_cluster(self, name, config, result, base_tags)

        # Phase 4: Node Pools
        config.node_pools.each do |pool_config|
          pool_ref = backend_module.create_node_pool(self, name, result.cluster, pool_config, base_tags)
          result.add_node_pool(pool_config.name, pool_ref)
        end

        result
      end

      # Create a standalone node pool for an existing cluster.
      #
      # @param cluster_name [Symbol] Parent cluster name
      # @param pool_name [Symbol] Node pool name
      # @param attributes [Hash] Node pool configuration
      # @param cluster_ref [ResourceReference] Reference to existing cluster
      # @param backend [Symbol] Backend name (:aws, :gcp, :azure, :hcloud)
      # @return [ResourceReference] Node pool reference
      def kubernetes_node_pool(cluster_name, pool_name, attributes = {}, cluster_ref:, backend:, tags: {})
        pool_config = Types::NodePoolConfig.new(attributes.merge(name: pool_name))
        backend_module = BackendRegistry.resolve(backend)
        backend_module.load_provider!

        base_tags = {
          KubernetesCluster: cluster_name.to_s,
          Backend: backend.to_s,
          ManagedBy: 'Pangea'
        }.merge(tags)

        backend_module.create_node_pool(self, cluster_name, cluster_ref, pool_config, base_tags)
      end

      # Result object from kubernetes_cluster() — holds all created references
      class ArchitectureResult
        attr_reader :name, :config, :node_pools
        attr_accessor :cluster, :network, :iam

        def initialize(name, config)
          @name = name
          @config = config
          @cluster = nil
          @network = nil
          @iam = nil
          @node_pools = {}
        end

        def add_node_pool(pool_name, ref)
          @node_pools[pool_name.to_sym] = ref
        end

        # Access outputs from the cluster reference
        def method_missing(method_name, *args, &block)
          if cluster&.respond_to?(method_name)
            cluster.public_send(method_name, *args, &block)
          else
            super
          end
        end

        def respond_to_missing?(method_name, include_private = false)
          cluster&.respond_to?(method_name, include_private) || super
        end

        def to_h
          {
            name: name,
            backend: config.backend,
            kubernetes_version: config.kubernetes_version,
            region: config.region,
            managed_kubernetes: config.managed_kubernetes?,
            cluster: cluster&.to_h,
            network: network_to_h,
            iam: iam_to_h,
            node_pools: node_pools.transform_values { |np| np.respond_to?(:to_h) ? np.to_h : np }
          }
        end

        private

        def network_to_h
          return nil unless network

          if network.is_a?(Hash)
            network.transform_values { |v| v.respond_to?(:to_h) ? v.to_h : v }
          else
            network.to_h
          end
        end

        def iam_to_h
          return nil unless iam

          if iam.is_a?(Hash)
            iam.transform_values { |v| v.respond_to?(:to_h) ? v.to_h : v }
          else
            iam.to_h
          end
        end
      end
    end
  end
end
