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

require 'pangea/contracts'
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
      # Phase pipeline: Network -> IAM -> Cluster -> Node Pools -> Addons
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

      # AWS-specific NetworkResult — extends the base contract with AWS fields.
      # is_a?(Pangea::Contracts::NetworkResult) returns true.
      class NetworkResult < Pangea::Contracts::NetworkResult
        attr_accessor :igw, :route_table, :etcd_bucket,
                      :flow_log, :flow_log_role,
                      :ssm_logs_bucket,
                      :kms_key

        def initialize
          super
          @igw = nil
          @route_table = nil
          @etcd_bucket = nil
          @flow_log = nil
          @flow_log_role = nil
          @ssm_logs_bucket = nil
          @kms_key = nil
        end

        def [](key)
          case key.to_sym
          when :igw then igw
          when :route_table then route_table
          when :etcd_bucket then etcd_bucket
          when :flow_log then flow_log
          when :flow_log_role then flow_log_role
          when :ssm_logs_bucket then ssm_logs_bucket
          when :kms_key then kms_key
          else super
          end
        end

        def to_h
          hash = super
          hash[:igw] = igw if igw
          hash[:route_table] = route_table if route_table
          hash[:etcd_bucket] = etcd_bucket if etcd_bucket
          hash[:flow_log] = flow_log if flow_log
          hash[:flow_log_role] = flow_log_role if flow_log_role
          hash[:ssm_logs_bucket] = ssm_logs_bucket if ssm_logs_bucket
          hash[:kms_key] = kms_key if kms_key
          hash
        end
      end

      # GCP-specific NetworkResult with firewall rules
      class GcpNetworkResult < Pangea::Contracts::NetworkResult
        attr_accessor :firewall_internal, :firewall_external

        def [](key)
          case key.to_sym
          when :firewall_internal then firewall_internal
          when :firewall_external then firewall_external
          else super
          end
        end

        def to_h
          hash = super
          hash[:firewall_internal] = firewall_internal if firewall_internal
          hash[:firewall_external] = firewall_external if firewall_external
          hash
        end
      end

      # Azure-specific NetworkResult with resource group, vnet, and NSG
      class AzureNetworkResult < Pangea::Contracts::NetworkResult
        attr_accessor :resource_group, :vnet, :nsg

        def [](key)
          case key.to_sym
          when :resource_group then resource_group
          when :vnet then vnet
          when :nsg then nsg
          else super
          end
        end

        def to_h
          hash = super
          hash[:resource_group] = resource_group if resource_group
          hash[:vnet] = vnet if vnet
          hash[:nsg] = nsg if nsg
          hash
        end
      end

      # Hetzner Cloud-specific NetworkResult with network (not VPC)
      class HcloudNetworkResult < Pangea::Contracts::NetworkResult
        attr_accessor :network

        def [](key)
          case key.to_sym
          when :network then network
          else super
          end
        end

        def to_h
          hash = super
          hash[:network] = network if network
          hash
        end
      end

      # AWS-specific IamResult — extends the base contract with AWS fields.
      # is_a?(Pangea::Contracts::IamResult) returns true.
      class IamResult < Pangea::Contracts::IamResult
        attr_accessor :log_group,
                      :ecr_policy, :etcd_policy, :logs_policy,
                      :ec2_policy, :ssm_policy,
                      :karpenter_role, :karpenter_profile

        def initialize
          super
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
          when :log_group then log_group
          when :ecr_policy then ecr_policy
          when :etcd_policy then etcd_policy
          when :logs_policy then logs_policy
          when :ec2_policy then ec2_policy
          when :ssm_policy then ssm_policy
          when :karpenter_role then karpenter_role
          when :karpenter_profile then karpenter_profile
          else super
          end
        end

        def to_h
          hash = super
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

      # AWS EKS-specific IamResult with cluster_role, cluster_policy_attachment, and node_role
      class AwsEksIamResult < IamResult
        attr_accessor :cluster_role, :cluster_policy_attachment, :node_role

        def [](key)
          case key.to_sym
          when :cluster_role then cluster_role
          when :cluster_policy_attachment then cluster_policy_attachment
          when :node_role then node_role
          else super
          end
        end

        def to_h
          hash = super
          hash[:cluster_role] = cluster_role if cluster_role
          hash[:cluster_policy_attachment] = cluster_policy_attachment if cluster_policy_attachment
          hash[:node_role] = node_role if node_role
          hash
        end
      end

      # GCP-specific IamResult with service account for nodes
      class GcpIamResult < IamResult
        attr_accessor :node_sa

        def [](key)
          case key.to_sym
          when :node_sa then node_sa
          else super
          end
        end

        def to_h
          hash = super
          hash[:node_sa] = node_sa if node_sa
          hash
        end
      end

      # AWS-specific ClusterResult — extends the base contract with AWS fields.
      # is_a?(Pangea::Contracts::ClusterResult) returns true.
      class ClusterResult < Pangea::Contracts::ClusterResult
        def asg_tg
          control_plane_ref.asg_tg
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

        def ipv4_address
          control_plane_ref.ipv4_address
        end
      end

      # Minimal accessor so templates can write result.cluster.security_group.id
      # Inherits from the base contract for is_a? compatibility.
      SecurityGroupAccessor = Pangea::Contracts::SecurityGroupAccessor

      # Result object from kubernetes_cluster() — holds all created references.
      # Inherits from base contract; provider-specific to_h calls config methods
      # that the typed ClusterConfig provides.
      class ArchitectureResult < Pangea::Contracts::ArchitectureResult
        # Override cluster= to wrap in the local ClusterResult subclass
        # (not the base Pangea::Contracts::ClusterResult)
        def cluster=(value)
          @cluster = if value.is_a?(Pangea::Contracts::ClusterResult)
                       value
                     elsif value
                       ClusterResult.new(value)
                     end
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
      end
    end
  end
end
