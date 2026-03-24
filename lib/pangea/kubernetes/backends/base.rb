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
    module Backends
      # Contract interface for Kubernetes backends. Each backend module
      # must implement these class methods (via class << self):
      #
      # Identity methods:
      #   backend_name        → Symbol (:aws, :gcp, :azure, :hcloud, etc.)
      #   managed_kubernetes? → true for EKS/GKE/AKS, false for NixOS/k3s
      #   required_gem        → String gem name to require
      #   load_provider!      → Require the provider gem (or raise LoadError)
      #
      # Infrastructure pipeline methods (all class-level):
      #   create_network(ctx, name, config, tags) → Pangea::Contracts::NetworkResult
      #   create_iam(ctx, name, config, tags)     → Pangea::Contracts::IamResult
      #   create_cluster(ctx, name, config, result, tags) → control plane ref
      #   create_node_pool(ctx, name, cluster_ref, pool_config, tags) → ResourceReference
      #
      # Backends implement all pipeline methods in `class << self` so they
      # are called as e.g. AwsNixos.create_network(ctx, ...).
      module Base
        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          def backend_name
            raise NotImplementedError, "#{self} must implement .backend_name"
          end

          def managed_kubernetes?
            raise NotImplementedError, "#{self} must implement .managed_kubernetes?"
          end

          def required_gem
            raise NotImplementedError, "#{self} must implement .required_gem"
          end

          def load_provider!
            require required_gem
          rescue LoadError => e
            raise LoadError,
                  "Backend #{backend_name} requires gem '#{required_gem}'. " \
                  "Add it to your Gemfile: gem '#{required_gem}'\n" \
                  "Original error: #{e.message}"
          end

          # Create networking resources (VPC, subnets, security groups, etc.).
          # Must return a Pangea::Contracts::NetworkResult (or subclass).
          #
          # @param ctx [Object] Synthesizer context (provides resource methods)
          # @param name [Symbol] Cluster name
          # @param config [Types::ClusterConfig] Cluster configuration
          # @param tags [Hash] Resource tags
          # @return [Pangea::Contracts::NetworkResult]
          def create_network(_ctx, _name, _config, _tags)
            raise NotImplementedError, "#{self} must implement .create_network"
          end

          # Create IAM resources (roles, policies, service accounts).
          # Must return a Pangea::Contracts::IamResult (or subclass).
          #
          # @param ctx [Object] Synthesizer context
          # @param name [Symbol] Cluster name
          # @param config [Types::ClusterConfig] Cluster configuration
          # @param tags [Hash] Resource tags
          # @return [Pangea::Contracts::IamResult]
          def create_iam(_ctx, _name, _config, _tags)
            raise NotImplementedError, "#{self} must implement .create_iam"
          end

          # Create the cluster control plane (EKS cluster, ASG+NLB, GKE cluster, etc.).
          # Return type is backend-specific (ControlPlaneRef, resource ref, etc.).
          #
          # @param ctx [Object] Synthesizer context
          # @param name [Symbol] Cluster name
          # @param config [Types::ClusterConfig] Cluster configuration
          # @param result [Pangea::Contracts::ArchitectureResult] Accumulated result with network/iam
          # @param tags [Hash] Resource tags
          # @return [Object] Control plane reference (wrapped in ClusterResult by Architecture)
          def create_cluster(_ctx, _name, _config, _result, _tags)
            raise NotImplementedError, "#{self} must implement .create_cluster"
          end

          # Create a worker node pool for the cluster.
          #
          # @param ctx [Object] Synthesizer context
          # @param name [Symbol] Cluster name
          # @param cluster_ref [Object] Reference to the control plane
          # @param pool_config [Types::NodePoolConfig] Node pool configuration
          # @param tags [Hash] Resource tags
          # @return [Object] Node pool resource reference
          def create_node_pool(_ctx, _name, _cluster_ref, _pool_config, _tags)
            raise NotImplementedError, "#{self} must implement .create_node_pool"
          end
        end
      end
    end
  end
end
