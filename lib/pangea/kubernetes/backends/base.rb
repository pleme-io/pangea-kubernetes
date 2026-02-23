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
      # must implement these class methods and instance methods.
      #
      # Class methods (via extend ClassMethods):
      #   backend_name    → Symbol (:aws, :gcp, :azure, :hcloud)
      #   managed_kubernetes? → true for EKS/GKE/AKS, false for k3s
      #   required_gem    → String gem name to require
      #
      # Instance methods (mixed into synthesizer context):
      #   create_cluster(name, config, tags)  → Hash of resources
      #   create_node_pool(name, cluster_ref, pool_config, tags) → ResourceReference
      #   create_network(name, config, tags)  → Hash of resources
      #   create_iam(name, config, tags)      → Hash of resources
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
        end

        # Create cluster resources. Returns a Hash:
        #   { cluster: ResourceReference, ...additional_resources }
        def create_cluster(_name, _config, _tags)
          raise NotImplementedError, "#{self.class} must implement #create_cluster"
        end

        # Create a single node pool. Returns ResourceReference.
        def create_node_pool(_name, _cluster_ref, _pool_config, _tags)
          raise NotImplementedError, "#{self.class} must implement #create_node_pool"
        end

        # Create networking resources (VPC, subnets, etc.). Returns Hash of refs.
        def create_network(_name, _config, _tags)
          raise NotImplementedError, "#{self.class} must implement #create_network"
        end

        # Create IAM resources (roles, policies). Returns Hash of refs.
        def create_iam(_name, _config, _tags)
          raise NotImplementedError, "#{self.class} must implement #create_iam"
        end
      end
    end
  end
end
