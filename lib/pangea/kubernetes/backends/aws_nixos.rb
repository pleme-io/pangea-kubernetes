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
require 'pangea/kubernetes/bare_metal/cloud_init'

module Pangea
  module Kubernetes
    module Backends
      # AWS NixOS backend — EC2 instances running NixOS with k3s/k8s
      # via blackmatter-kubernetes modules.
      #
      # Uses:
      #   - EC2 instances for control plane (static, no ASG)
      #   - Auto Scaling Groups for worker node pools
      #   - VPC + Security Groups for networking
      #   - Launch Templates for NixOS AMI + cloud-init
      #
      # No managed K8s services (EKS) — all k3s/k8s managed by NixOS.
      module AwsNixos
        include Base

        class << self
          def backend_name = :aws_nixos
          def managed_kubernetes? = false
          def required_gem = 'pangea-aws'

          def load_provider!
            require required_gem
          rescue LoadError => e
            raise LoadError,
                  "Backend :aws_nixos requires gem 'pangea-aws'. " \
                  "Add it to your Gemfile: gem 'pangea-aws'\n" \
                  "Original error: #{e.message}"
          end

          # Create VPC + subnets + security groups
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

            # Internet gateway for public access
            network[:igw] = ctx.aws_internet_gateway(
              :"#{name}_igw",
              vpc_id: network[:vpc].id,
              tags: tags.merge(Name: "#{name}-igw")
            )

            # Subnets in 2 AZs
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

            # Security group for k3s/k8s nodes
            network[:sg] = ctx.aws_security_group(
              :"#{name}_sg",
              name: "#{name}-k8s-nodes",
              description: "Security group for #{name} k8s/k3s NixOS nodes",
              vpc_id: network[:vpc].id,
              ingress: security_group_rules(config.distribution),
              egress: [{ from_port: 0, to_port: 0, protocol: '-1', cidr_blocks: ['0.0.0.0/0'] }],
              tags: tags.merge(Name: "#{name}-sg")
            )

            network
          end

          # SSH key pair for EC2 instances — no IAM roles needed for NixOS
          def create_iam(ctx, name, config, tags)
            iam = {}

            # Instance profile for EC2 (minimal — no EKS policies needed)
            assume_role_policy = {
              Version: '2012-10-17',
              Statement: [{
                Effect: 'Allow',
                Principal: { Service: 'ec2.amazonaws.com' },
                Action: 'sts:AssumeRole'
              }]
            }.to_json

            iam[:instance_role] = ctx.aws_iam_role(
              :"#{name}_instance_role",
              name: "#{name}-nixos-instance-role",
              assume_role_policy: assume_role_policy,
              tags: tags.merge(Name: "#{name}-instance-role")
            )

            iam[:instance_profile] = ctx.aws_iam_instance_profile(
              :"#{name}_instance_profile",
              name: "#{name}-nixos-instance-profile",
              role: iam[:instance_role].name
            )

            iam
          end

          # Create control plane EC2 instances (static, no ASG)
          def create_cluster(ctx, name, config, result, tags)
            system_pool = config.system_node_pool
            instance_type = system_pool.instance_types.first
            ami_id = config.ami_id || config.nixos&.image_id || 'ami-nixos-latest'

            subnet_ids = if config.network&.subnet_ids&.any?
                           config.network.subnet_ids
                         elsif result.network
                           result.network.select { |k, _| k.to_s.start_with?('subnet_') }.values.map(&:id)
                         else
                           []
                         end

            sg_id = result.network&.dig(:sg)&.id

            cp_count = [system_pool.min_size, 1].max
            servers = []

            cp_count.times do |idx|
              cloud_init = BareMetal::CloudInit.generate(
                cluster_name: name.to_s,
                distribution: config.distribution,
                profile: config.profile,
                distribution_track: config.distribution_track || config.kubernetes_version,
                role: 'server',
                node_index: idx,
                cluster_init: idx.zero?,
                fluxcd: config.fluxcd&.to_h
              )

              server = ctx.aws_instance(
                :"#{name}_cp_#{idx}",
                ami: ami_id,
                instance_type: instance_type,
                subnet_id: subnet_ids[idx % subnet_ids.size],
                vpc_security_group_ids: sg_id ? [sg_id] : [],
                key_name: config.key_pair,
                iam_instance_profile: result.iam&.dig(:instance_profile)&.name,
                user_data: cloud_init,
                root_block_device: { volume_size: system_pool.disk_size_gb, volume_type: 'gp3' },
                tags: tags.merge(
                  Name: "#{name}-cp-#{idx}",
                  Role: 'control-plane',
                  Distribution: config.distribution.to_s
                )
              )

              servers << server
            end

            servers.first
          end

          # Create worker node pool via Launch Template + Auto Scaling Group
          def create_node_pool(ctx, name, cluster_ref, pool_config, tags)
            pool_name = :"#{name}_#{pool_config.name}"
            instance_type = pool_config.instance_types.first

            cloud_init = BareMetal::CloudInit.generate(
              cluster_name: name.to_s,
              distribution: tags[:Distribution]&.to_sym || :k3s,
              profile: tags[:Profile] || 'cilium-standard',
              distribution_track: tags[:DistributionTrack] || '1.34',
              role: 'agent',
              node_index: 0,
              cluster_init: false,
              join_server: cluster_ref.ipv4_address
            )

            # Launch Template
            lt = ctx.aws_launch_template(
              :"#{pool_name}_lt",
              name: "#{name}-#{pool_config.name}-lt",
              image_id: tags[:AmiId] || 'ami-nixos-latest',
              instance_type: instance_type,
              key_name: tags[:KeyPair],
              user_data: cloud_init,
              block_device_mappings: [{
                device_name: '/dev/xvda',
                ebs: { volume_size: pool_config.disk_size_gb, volume_type: 'gp3' }
              }],
              tag_specifications: [{
                resource_type: 'instance',
                tags: tags.merge(
                  Name: "#{name}-#{pool_config.name}",
                  Role: 'worker',
                  NodePool: pool_config.name.to_s
                )
              }]
            )

            # Auto Scaling Group
            asg = ctx.aws_autoscaling_group(
              :"#{pool_name}_asg",
              name: "#{name}-#{pool_config.name}-asg",
              min_size: pool_config.min_size,
              max_size: pool_config.max_size,
              desired_capacity: pool_config.effective_desired_size,
              launch_template: {
                id: lt.id,
                version: '$Latest'
              },
              vpc_zone_identifier: tags[:SubnetIds] || [],
              health_check_type: 'EC2',
              health_check_grace_period: 300,
              tags: [
                { key: 'Name', value: "#{name}-#{pool_config.name}", propagate_at_launch: true },
                { key: 'KubernetesCluster', value: name.to_s, propagate_at_launch: true },
                { key: 'NodePool', value: pool_config.name.to_s, propagate_at_launch: true }
              ]
            )

            asg
          end

          private

          def security_group_rules(distribution)
            rules = [
              { from_port: 22, to_port: 22, protocol: 'tcp', cidr_blocks: ['0.0.0.0/0'], description: 'SSH' },
              { from_port: 80, to_port: 80, protocol: 'tcp', cidr_blocks: ['0.0.0.0/0'], description: 'HTTP' },
              { from_port: 443, to_port: 443, protocol: 'tcp', cidr_blocks: ['0.0.0.0/0'], description: 'HTTPS' },
              { from_port: 6443, to_port: 6443, protocol: 'tcp', cidr_blocks: ['0.0.0.0/0'], description: 'K8s API' },
              { from_port: 10250, to_port: 10250, protocol: 'tcp', cidr_blocks: ['10.0.0.0/8'], description: 'Kubelet' },
              { from_port: 2379, to_port: 2380, protocol: 'tcp', cidr_blocks: ['10.0.0.0/8'], description: 'etcd' },
              { from_port: 8472, to_port: 8472, protocol: 'udp', cidr_blocks: ['10.0.0.0/8'], description: 'VXLAN' }
            ]

            if distribution.to_sym == :kubernetes
              rules += [
                { from_port: 10257, to_port: 10257, protocol: 'tcp', cidr_blocks: ['10.0.0.0/8'], description: 'controller-manager' },
                { from_port: 10259, to_port: 10259, protocol: 'tcp', cidr_blocks: ['10.0.0.0/8'], description: 'scheduler' }
              ]
            end

            rules
          end
        end
      end
    end
  end
end
