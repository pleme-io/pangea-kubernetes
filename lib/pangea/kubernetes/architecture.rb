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
        # VPN config comes in two forms:
        # 1. Typed (VpnConfig with :links) — validated by dry-struct, used by NixOS backends
        # 2. Cloud-init passthrough (flat hash with :interface, :port, etc.) — passed
        #    as-is to cloud-init for AWS/cloud backends where the node configures WireGuard
        # Both are legitimate. Only validate if the hash has :links (typed form).

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

      # Typed result object for the network phase.
      # Provides named accessors instead of raw hash access, ensuring backends
      # and templates agree on the contract.
      class NetworkResult
        attr_reader :vpc, :igw, :route_table, :sg, :etcd_bucket

        def initialize
          @vpc = nil
          @igw = nil
          @route_table = nil
          @sg = nil
          @etcd_bucket = nil
          @subnets = []
        end

        # Set core network resources
        attr_writer :vpc, :igw, :route_table, :sg, :etcd_bucket

        # Add a subnet to the ordered list
        def add_subnet(name, ref)
          @subnets << { name: name, ref: ref }
        end

        # All subnets as an array of resource references
        def subnets
          @subnets.map { |s| s[:ref] }
        end

        # Alias used by templates (e.g., akeyless_dev_cluster.rb)
        alias public_subnets subnets

        # Subnet IDs as an array of strings (terraform refs)
        def subnet_ids
          subnets.map(&:id)
        end

        # Hash-style access for backward compatibility with existing code
        # that uses result.network[:vpc], result.network[:sg], etc.
        def [](key)
          case key.to_sym
          when :vpc then vpc
          when :igw then igw
          when :route_table then route_table
          when :sg then sg
          when :etcd_bucket then etcd_bucket
          when :public_subnets then public_subnets
          when :subnet_ids then subnet_ids
          else
            # Support :subnet_a, :subnet_b legacy keys
            match = @subnets.find { |s| s[:name] == key.to_sym }
            match&.dig(:ref)
          end
        end

        # Hash-like iteration for backward compatibility (e.g., resolve_subnet_ids
        # in aws_nixos.rb uses .select { |k, _| k.to_s.start_with?('subnet_') })
        def select(&block)
          to_h.select(&block)
        end

        def to_h
          hash = {}
          hash[:vpc] = vpc if vpc
          hash[:igw] = igw if igw
          hash[:route_table] = route_table if route_table
          hash[:sg] = sg if sg
          hash[:etcd_bucket] = etcd_bucket if etcd_bucket
          @subnets.each { |s| hash[s[:name]] = s[:ref] }
          hash
        end

        def dig(*keys)
          to_h.dig(*keys)
        end

        # Hash-like key checks for backward compatibility with RSpec have_key matcher
        def key?(key)
          !self[key].nil?
        end
        alias has_key? key?
        alias include? key?
      end

      # Typed result object for the IAM phase.
      class IamResult
        attr_accessor :role, :instance_profile, :log_group,
                      :ecr_policy, :etcd_policy, :logs_policy,
                      :ec2_policy, :ssm_policy,
                      :karpenter_role, :karpenter_profile

        def initialize
          @role = nil
          @instance_profile = nil
          @log_group = nil
          @ecr_policy = nil
          @etcd_policy = nil
          @logs_policy = nil
          @ec2_policy = nil
          @ssm_policy = nil
          @karpenter_role = nil
          @karpenter_profile = nil
        end

        # Hash-style access for backward compatibility
        def [](key)
          case key.to_sym
          when :role then role
          when :instance_profile then instance_profile
          when :log_group then log_group
          when :ecr_policy then ecr_policy
          when :etcd_policy then etcd_policy
          when :logs_policy then logs_policy
          when :ec2_policy then ec2_policy
          when :ssm_policy then ssm_policy
          when :karpenter_role then karpenter_role
          when :karpenter_profile then karpenter_profile
          end
        end

        def dig(*keys)
          to_h.dig(*keys)
        end

        # Hash-like key checks for backward compatibility with RSpec have_key matcher
        def key?(key)
          !self[key].nil?
        end
        alias has_key? key?
        alias include? key?

        def to_h
          hash = {}
          hash[:role] = role if role
          hash[:instance_profile] = instance_profile if instance_profile
          hash[:log_group] = log_group if log_group
          hash[:ecr_policy] = ecr_policy if ecr_policy
          hash[:etcd_policy] = etcd_policy if etcd_policy
          hash[:logs_policy] = logs_policy if logs_policy
          hash[:ec2_policy] = ec2_policy if ec2_policy
          hash[:ssm_policy] = ssm_policy if ssm_policy
          hash[:karpenter_role] = karpenter_role if karpenter_role
          hash[:karpenter_profile] = karpenter_profile if karpenter_profile
          hash
        end
      end

      # Typed result object for the cluster phase.
      # Wraps the backend-specific control plane reference and provides
      # named accessors for common cluster outputs.
      class ClusterResult
        attr_reader :control_plane_ref

        def initialize(control_plane_ref)
          @control_plane_ref = control_plane_ref
        end

        # Named accessors for common cluster components
        def nlb
          control_plane_ref.nlb
        end

        def asg
          control_plane_ref.asg
        end

        def launch_template
          control_plane_ref.lt
        end
        alias lt launch_template

        def target_group
          control_plane_ref.tg
        end
        alias tg target_group

        def listener
          control_plane_ref.listener
        end

        def asg_tg
          control_plane_ref.asg_tg
        end

        # Security group ID — the SG used for cluster nodes
        def sg_id
          control_plane_ref.sg_id
        end

        # Convenience: return a pseudo-reference for security_group access
        # Templates use result.cluster.security_group.id
        def security_group
          SecurityGroupAccessor.new(control_plane_ref.sg_id)
        end

        def subnet_ids
          control_plane_ref.subnet_ids
        end

        def instance_profile_name
          control_plane_ref.instance_profile_name
        end

        def ami_id
          control_plane_ref.ami_id
        end

        def key_name
          control_plane_ref.key_name
        end

        # Delegate ipv4_address, id, arn to control_plane_ref
        def ipv4_address
          control_plane_ref.ipv4_address
        end

        def id
          control_plane_ref.id
        end

        def arn
          control_plane_ref.arn
        end

        def to_h
          control_plane_ref.respond_to?(:to_h) ? control_plane_ref.to_h : {}
        end

        # Forward unknown methods to control_plane_ref for backward compatibility
        def method_missing(method_name, *args, &block)
          if control_plane_ref.respond_to?(method_name)
            control_plane_ref.public_send(method_name, *args, &block)
          else
            super
          end
        end

        def respond_to_missing?(method_name, include_private = false)
          control_plane_ref.respond_to?(method_name, include_private) || super
        end
      end

      # Minimal accessor so templates can write result.cluster.security_group.id
      class SecurityGroupAccessor
        attr_reader :id

        def initialize(sg_id)
          @id = sg_id
        end
      end

      # Result object from kubernetes_cluster() — holds all created references
      class ArchitectureResult
        attr_reader :name, :config, :node_pools
        attr_accessor :network, :iam

        def initialize(name, config)
          @name = name
          @config = config
          @cluster = nil
          @network = nil
          @iam = nil
          @node_pools = {}
        end

        # Cluster getter — always returns a ClusterResult wrapper
        def cluster
          @cluster
        end

        # Cluster setter — wraps raw control plane refs in ClusterResult
        def cluster=(value)
          @cluster = if value.is_a?(ClusterResult)
                       value
                     elsif value
                       ClusterResult.new(value)
                     end
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

          if network.respond_to?(:to_h)
            result = network.to_h
            result.is_a?(Hash) ? result.transform_values { |v| v.respond_to?(:to_h) ? v.to_h : v } : result
          else
            network
          end
        end

        def iam_to_h
          return nil unless iam

          if iam.respond_to?(:to_h)
            result = iam.to_h
            result.is_a?(Hash) ? result.transform_values { |v| v.respond_to?(:to_h) ? v.to_h : v } : result
          else
            iam
          end
        end
      end
    end
  end
end
