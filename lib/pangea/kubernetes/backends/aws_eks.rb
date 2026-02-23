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

require 'pangea/kubernetes/backends/base'

module Pangea
  module Kubernetes
    module Backends
      # AWS EKS backend — creates managed EKS clusters with VPC, IAM, and node groups.
      module AwsEks
        include Base

        class << self
          def backend_name = :aws
          def managed_kubernetes? = true
          def required_gem = 'pangea-aws'

          def load_provider!
            require required_gem
          rescue LoadError => e
            raise LoadError,
                  "Backend :aws requires gem 'pangea-aws'. " \
                  "Add it to your Gemfile: gem 'pangea-aws'\n" \
                  "Original error: #{e.message}"
          end

          # Create VPC + subnets for the EKS cluster
          def create_network(ctx, name, config, tags)
            network = {}

            vpc_cidr = config.network&.vpc_cidr || '10.0.0.0/16'
            network[:vpc] = ctx.aws_vpc(
              :"#{name}_vpc",
              cidr_block: vpc_cidr,
              enable_dns_hostnames: true,
              enable_dns_support: true,
              tags: tags.merge(Name: "#{name}-vpc")
            )

            # Create 2 subnets in different AZs (EKS requirement)
            %w[a b].each_with_index do |az_suffix, idx|
              network[:"subnet_#{az_suffix}"] = ctx.aws_subnet(
                :"#{name}_subnet_#{az_suffix}",
                vpc_id: network[:vpc].id,
                cidr_block: "10.0.#{idx}.0/24",
                availability_zone: "#{config.region}#{az_suffix}",
                map_public_ip_on_launch: true,
                tags: tags.merge(Name: "#{name}-subnet-#{az_suffix}")
              )
            end

            network
          end

          # Create IAM role for the EKS cluster and node groups
          def create_iam(ctx, name, config, tags)
            iam = {}

            # Cluster role — use provided role_arn or create one
            unless config.role_arn
              assume_role_policy = {
                Version: '2012-10-17',
                Statement: [{
                  Effect: 'Allow',
                  Principal: { Service: 'eks.amazonaws.com' },
                  Action: 'sts:AssumeRole'
                }]
              }.to_json

              iam[:cluster_role] = ctx.aws_iam_role(
                :"#{name}_cluster_role",
                name: "#{name}-eks-cluster-role",
                assume_role_policy: assume_role_policy,
                tags: tags.merge(Name: "#{name}-cluster-role")
              )

              iam[:cluster_policy_attachment] = ctx.aws_iam_role_policy_attachment(
                :"#{name}_cluster_policy",
                role: iam[:cluster_role].name,
                policy_arn: 'arn:aws:iam::aws:policy/AmazonEKSClusterPolicy'
              )
            end

            # Node role
            node_assume_role_policy = {
              Version: '2012-10-17',
              Statement: [{
                Effect: 'Allow',
                Principal: { Service: 'ec2.amazonaws.com' },
                Action: 'sts:AssumeRole'
              }]
            }.to_json

            iam[:node_role] = ctx.aws_iam_role(
              :"#{name}_node_role",
              name: "#{name}-eks-node-role",
              assume_role_policy: node_assume_role_policy,
              tags: tags.merge(Name: "#{name}-node-role")
            )

            %w[AmazonEKSWorkerNodePolicy AmazonEKS_CNI_Policy AmazonEC2ContainerRegistryReadOnly].each do |policy|
              ctx.aws_iam_role_policy_attachment(
                :"#{name}_node_#{policy.downcase.gsub(/[^a-z0-9]/, '_')}",
                role: iam[:node_role].name,
                policy_arn: "arn:aws:iam::aws:policy/#{policy}"
              )
            end

            iam
          end

          # Create the EKS cluster
          def create_cluster(ctx, name, config, result, tags)
            # Determine subnet IDs
            subnet_ids = if config.network&.subnet_ids&.any?
                           config.network.subnet_ids
                         elsif result.network
                           result.network.select { |k, _| k.to_s.start_with?('subnet_') }.values.map(&:id)
                         else
                           []
                         end

            # Determine role ARN
            role_arn = config.role_arn || result.iam&.dig(:cluster_role)&.arn

            cluster_attrs = {
              name: "#{name}-cluster",
              role_arn: role_arn,
              version: config.kubernetes_version,
              vpc_config: {
                subnet_ids: subnet_ids,
                endpoint_private_access: config.network&.private_endpoint || true,
                endpoint_public_access: config.network&.public_endpoint || false,
                security_group_ids: config.network&.security_group_ids || []
              },
              tags: tags.merge(Name: "#{name}-cluster")
            }

            cluster_attrs[:enabled_cluster_log_types] = config.logging if config.logging.any?

            if config.encryption_at_rest
              cluster_attrs[:encryption_config] = [{
                resources: ['secrets']
              }]
            end

            ctx.aws_eks_cluster(:"#{name}_cluster", cluster_attrs)
          end

          # Create an EKS managed node group
          def create_node_pool(ctx, name, cluster_ref, pool_config, tags)
            pool_name = :"#{name}_#{pool_config.name}"

            node_group_attrs = {
              cluster_name: cluster_ref.name,
              node_group_name: "#{name}-#{pool_config.name}",
              node_role_arn: "${aws_iam_role.#{name}_node_role.arn}",
              instance_types: pool_config.instance_types,
              scaling_config: {
                desired_size: pool_config.effective_desired_size,
                min_size: pool_config.min_size,
                max_size: pool_config.max_size
              },
              disk_size: pool_config.disk_size_gb,
              tags: tags.merge(
                Name: "#{name}-#{pool_config.name}",
                NodePool: pool_config.name.to_s
              )
            }

            node_group_attrs[:labels] = pool_config.labels if pool_config.labels.any?

            if pool_config.taints.any?
              node_group_attrs[:taint] = pool_config.taints.map do |t|
                { key: t[:key], value: t[:value], effect: t[:effect] }
              end
            end

            ctx.aws_eks_node_group(pool_name, node_group_attrs)
          end
        end
      end
    end
  end
end
