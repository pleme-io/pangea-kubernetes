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
require 'pangea/kubernetes/backends/nixos_base'

module Pangea
  module Kubernetes
    module Backends
      # AWS NixOS backend — EC2 instances running NixOS with k3s/k8s
      # via blackmatter-kubernetes modules.
      #
      # Security invariants (enforced by this backend):
      # - NO wildcard IAM actions — every action listed individually
      # - NO public SSH or K8s API — restricted to VPC CIDR
      # - prevent_destroy on stateful resources (IAM role, VPC)
      # - IMDSv2 required on all instances (SSRF protection)
      # - Session duration capped at 1 hour
      # - 5 least-privilege IAM policies (ECR, S3, CloudWatch, EC2, SSM)
      # - CloudWatch log group with 30-day retention
      module AwsNixos
        include Base
        extend NixosBase

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

          # ── Phase 1: Network + Storage ────────────────────────────────
          def create_network(ctx, name, config, tags)
            validate_cidr_restrictions!(config)
            network = {}

            # S3 bucket for etcd backups (versioned, encrypted, no public access)
            etcd_bucket = config.tags[:etcd_backup_bucket] || config.tags['etcd_backup_bucket'] || "#{name}-etcd-backups"
            network[:etcd_bucket] = ctx.aws_s3_bucket(
              :"#{name}_etcd",
              bucket: etcd_bucket,
              tags: tags.merge(Name: etcd_bucket)
            )
            ctx.aws_s3_bucket_versioning(
              :"#{name}_etcd_versioning",
              bucket: network[:etcd_bucket].id,
              versioning_configuration: { status: 'Enabled' }
            )
            ctx.aws_s3_bucket_encryption(
              :"#{name}_etcd_encryption",
              bucket: network[:etcd_bucket].id,
              server_side_encryption_configuration: {
                rule: [{ apply_server_side_encryption_by_default: { sse_algorithm: 'aws:kms' }, bucket_key_enabled: true }],
              }
            )
            ctx.aws_s3_bucket_public_access_block(
              :"#{name}_etcd_public_access",
              bucket: network[:etcd_bucket].id,
              block_public_acls: true,
              block_public_policy: true,
              ignore_public_acls: true,
              restrict_public_buckets: true
            )

            vpc_cidr = config.network&.vpc_cidr || '10.0.0.0/16'
            network[:vpc] = ctx.aws_vpc(
              :"#{name}_vpc",
              cidr_block: vpc_cidr,
              enable_dns_hostnames: true,
              enable_dns_support: true,
              tags: tags.merge(Name: "#{name}-vpc"),
              lifecycle: { prevent_destroy: true }
            )

            network[:igw] = ctx.aws_internet_gateway(
              :"#{name}_igw",
              vpc_id: network[:vpc].id,
              tags: tags.merge(Name: "#{name}-igw")
            )

            # Route table for IGW (required for internet access)
            network[:route_table] = ctx.aws_route_table(
              :"#{name}_rt",
              vpc_id: network[:vpc].id,
              route: [{ cidr_block: '0.0.0.0/0', gateway_id: network[:igw].id }],
              tags: tags.merge(Name: "#{name}-rt")
            )

            # Subnets in 2 AZs
            %w[a b].each_with_index do |az_suffix, idx|
              subnet = ctx.aws_subnet(
                :"#{name}_subnet_#{az_suffix}",
                vpc_id: network[:vpc].id,
                cidr_block: "10.0.#{idx}.0/24",
                availability_zone: "#{config.region}#{az_suffix}",
                map_public_ip_on_launch: true,
                tags: tags.merge(Name: "#{name}-subnet-#{az_suffix}")
              )
              network[:"subnet_#{az_suffix}"] = subnet

              # Associate subnet with route table
              ctx.aws_route_table_association(
                :"#{name}_rta_#{az_suffix}",
                subnet_id: subnet.id,
                route_table_id: network[:route_table].id
              )
            end

            # Security group — K3s ports restricted to VPC CIDR
            network[:sg] = ctx.aws_security_group(
              :"#{name}_sg",
              name: "#{name}-k8s-nodes",
              description: "Security group for #{name} k8s/k3s NixOS nodes",
              vpc_id: network[:vpc].id,
              ingress: aws_security_group_rules(config, vpc_cidr),
              egress: [{ from_port: 0, to_port: 0, protocol: '-1', cidr_blocks: ['0.0.0.0/0'] }],
              tags: tags.merge(Name: "#{name}-sg")
            )

            network
          end

          # ── Phase 2: IAM (least-privilege) ───────────────────────────
          def create_iam(ctx, name, config, tags)
            iam = {}
            account_id = config.tags[:account_id] || config.tags['account_id']
            if account_id.nil? || account_id == 'CHANGEME'
              raise ArgumentError,
                    "account_id is required for IAM policy scoping. " \
                    "Set ACCOUNT_ID env var or pass account_id in tags."
            end
            region = config.region
            etcd_bucket = config.tags[:etcd_backup_bucket] || config.tags['etcd_backup_bucket'] || "#{name}-etcd-backups"
            log_group = "/k3s/#{name}"

            # EC2-only assume-role trust policy
            assume_role_policy = {
              Version: '2012-10-17',
              Statement: [{
                Effect: 'Allow',
                Principal: { Service: 'ec2.amazonaws.com' },
                Action: 'sts:AssumeRole'
              }]
            }.to_json

            iam[:role] = ctx.aws_iam_role(
              :"#{name}_node_role",
              name: "#{name}-node-role",
              description: "Least-privilege role for #{name} K3s cluster nodes",
              assume_role_policy: assume_role_policy,
              max_session_duration: 3600,
              tags: tags.merge(Name: "#{name}-node-role"),
              lifecycle: { prevent_destroy: true }
            )

            iam[:instance_profile] = ctx.aws_iam_instance_profile(
              :"#{name}_node_profile",
              name: "#{name}-node-profile",
              role: iam[:role].ref(:name),
              tags: tags.merge(Name: "#{name}-node-profile")
            )

            # ── Policy: ECR Read-Only ────────────────────────────────
            ecr_resource = ["arn:aws:ecr:#{region}:#{account_id}:repository/*"]

            iam[:ecr_policy] = ctx.aws_iam_policy(
              :"#{name}_ecr_read",
              name: "#{name}-ecr-read",
              description: "ECR read-only for #{name} K3s nodes",
              policy: {
                Version: '2012-10-17',
                Statement: [{
                  Sid: 'ECRReadOnly',
                  Effect: 'Allow',
                  Action: %w[
                    ecr:GetDownloadUrlForLayer
                    ecr:BatchGetImage
                    ecr:BatchCheckLayerAvailability
                    ecr:DescribeRepositories
                    ecr:ListImages
                  ],
                  Resource: ecr_resource,
                }, {
                  Sid: 'ECRAuth',
                  Effect: 'Allow',
                  Action: ['ecr:GetAuthorizationToken'],
                  Resource: ['*'],
                }],
              },
              tags: tags,
            )
            ctx.aws_iam_role_policy_attachment(:"#{name}_ecr_read",
                                              role: iam[:role].ref(:name), policy_arn: iam[:ecr_policy].ref(:arn))

            # ── Policy: S3 Etcd Backup ───────────────────────────────
            iam[:etcd_policy] = ctx.aws_iam_policy(
              :"#{name}_etcd_backup",
              name: "#{name}-etcd-backup",
              description: "S3 etcd backup access for #{name} K3s nodes",
              policy: {
                Version: '2012-10-17',
                Statement: [{
                  Sid: 'EtcdBackupReadWrite',
                  Effect: 'Allow',
                  Action: %w[s3:GetObject s3:PutObject s3:ListBucket],
                  Resource: ["arn:aws:s3:::#{etcd_bucket}", "arn:aws:s3:::#{etcd_bucket}/*"],
                }],
              },
              tags: tags,
            )
            ctx.aws_iam_role_policy_attachment(:"#{name}_etcd_backup",
                                              role: iam[:role].ref(:name), policy_arn: iam[:etcd_policy].ref(:arn))

            # ── Policy: CloudWatch Logs ──────────────────────────────
            logs_resource = ["arn:aws:logs:#{region}:#{account_id}:log-group:#{log_group}:*"]

            iam[:logs_policy] = ctx.aws_iam_policy(
              :"#{name}_logs",
              name: "#{name}-cloudwatch-logs",
              description: "CloudWatch log access for #{name} K3s nodes",
              policy: {
                Version: '2012-10-17',
                Statement: [{
                  Sid: 'CloudWatchLogs',
                  Effect: 'Allow',
                  Action: %w[logs:CreateLogStream logs:PutLogEvents logs:DescribeLogStreams],
                  Resource: logs_resource,
                }],
              },
              tags: tags,
            )
            ctx.aws_iam_role_policy_attachment(:"#{name}_logs",
                                              role: iam[:role].ref(:name), policy_arn: iam[:logs_policy].ref(:arn))

            # ── Policy: EC2 Describe (node discovery) ────────────────
            ec2_statement = {
              Sid: 'EC2Describe',
              Effect: 'Allow',
              Action: %w[
                ec2:DescribeInstances
                ec2:DescribeTags
                ec2:DescribeVolumes
                ec2:DescribeNetworkInterfaces
                ec2:DescribeSecurityGroups
                ec2:DescribeSubnets
                ec2:DescribeVpcs
              ],
              Resource: ['*'],
            }
            ec2_statement[:Condition] = { StringEquals: { 'ec2:Region': region } }

            iam[:ec2_policy] = ctx.aws_iam_policy(
              :"#{name}_ec2_describe",
              name: "#{name}-ec2-describe",
              description: "EC2 read-only metadata for #{name} K3s nodes",
              policy: { Version: '2012-10-17', Statement: [ec2_statement] },
              tags: tags,
            )
            ctx.aws_iam_role_policy_attachment(:"#{name}_ec2_describe",
                                              role: iam[:role].ref(:name), policy_arn: iam[:ec2_policy].ref(:arn))

            # ── Policy: SSM Session Manager ──────────────────────────
            iam[:ssm_policy] = ctx.aws_iam_policy(
              :"#{name}_ssm",
              name: "#{name}-ssm-session",
              description: "SSM session access for #{name} K3s nodes",
              policy: {
                Version: '2012-10-17',
                Statement: [{
                  Sid: 'SSMCore',
                  Effect: 'Allow',
                  Action: %w[
                    ssm:UpdateInstanceInformation
                    ssmmessages:CreateControlChannel
                    ssmmessages:CreateDataChannel
                    ssmmessages:OpenControlChannel
                    ssmmessages:OpenDataChannel
                  ],
                  Resource: ['*'],
                }, {
                  Sid: 'SSMSessionLogs',
                  Effect: 'Allow',
                  Action: ['s3:PutObject'],
                  Resource: ["arn:aws:s3:::#{etcd_bucket}/ssm-logs/*"],
                }],
              },
              tags: tags,
            )
            ctx.aws_iam_role_policy_attachment(:"#{name}_ssm",
                                              role: iam[:role].ref(:name), policy_arn: iam[:ssm_policy].ref(:arn))

            # ── CloudWatch Log Group ─────────────────────────────────
            iam[:log_group] = ctx.aws_cloudwatch_log_group(
              :"#{name}_logs",
              name: log_group,
              retention_in_days: 30,
              tags: tags.merge(Name: "#{name}-logs")
            )

            iam
          end

          # ── Phase 3: Cluster (control plane) ─────────────────────────
          def create_cluster(ctx, name, config, result, tags)
            nixos_create_cluster(ctx, name, config, result, tags)
          end

          # ── Phase 4: Node pools (workers) ────────────────────────────
          def create_node_pool(ctx, name, cluster_ref, pool_config, tags)
            nixos_create_node_pool(ctx, name, cluster_ref, pool_config, tags)
          end

          # --- NixosBase template hooks ---

          def create_compute_instance(ctx, name, config, result, cloud_init, index, tags)
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

            ctx.aws_instance(
              :"#{name}_cp_#{index}",
              ami: ami_id,
              instance_type: instance_type,
              subnet_id: subnet_ids[index % subnet_ids.size],
              vpc_security_group_ids: sg_id ? [sg_id] : [],
              key_name: config.key_pair,
              iam_instance_profile: result.iam&.dig(:instance_profile)&.name,
              user_data: cloud_init,
              root_block_device: {
                volume_size: system_pool.disk_size_gb,
                volume_type: 'gp3',
                encrypted: true,
              },
              metadata_options: {
                http_endpoint: 'enabled',
                http_tokens: 'required',
                http_put_response_hop_limit: 1,
                instance_metadata_tags: 'enabled',
              },
              tags: tags.merge(
                Name: "#{name}-cp-#{index}",
                Role: 'control-plane',
                Distribution: config.distribution.to_s
              )
            )
          end

          def create_worker_pool(ctx, name, _cluster_ref, pool_config, cloud_init, tags)
            pool_name = :"#{name}_#{pool_config.name}"
            instance_type = pool_config.instance_types.first

            lt = ctx.aws_launch_template(
              :"#{pool_name}_lt",
              name: "#{name}-#{pool_config.name}-lt",
              image_id: tags[:AmiId] || 'ami-nixos-latest',
              instance_type: instance_type,
              key_name: tags[:KeyPair],
              user_data: cloud_init,
              metadata_options: {
                http_endpoint: 'enabled',
                http_tokens: 'required',
                http_put_response_hop_limit: 1,
                instance_metadata_tags: 'enabled',
              },
              block_device_mappings: [{
                device_name: '/dev/xvda',
                ebs: {
                  volume_size: pool_config.disk_size_gb,
                  volume_type: 'gp3',
                  encrypted: true,
                }
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

            ctx.aws_autoscaling_group(
              :"#{pool_name}_asg",
              name: "#{name}-#{pool_config.name}-asg",
              min_size: pool_config.min_size,
              max_size: pool_config.max_size,
              desired_capacity: pool_config.effective_desired_size,
              launch_template: { id: lt.id, version: '$Latest' },
              vpc_zone_identifier: tags[:SubnetIds] || [],
              health_check_type: 'EC2',
              health_check_grace_period: 300,
              tags: [
                { key: 'Name', value: "#{name}-#{pool_config.name}", propagate_at_launch: true },
                { key: 'KubernetesCluster', value: name.to_s, propagate_at_launch: true },
                { key: 'NodePool', value: pool_config.name.to_s, propagate_at_launch: true }
              ]
            )
          end

          private

          # Reject 0.0.0.0/0 for SSH and K8s API — these must never be public.
          def validate_cidr_restrictions!(config)
            ssh_cidr = config.tags[:ssh_cidr] || config.tags['ssh_cidr']
            api_cidr = config.tags[:api_cidr] || config.tags['api_cidr']
            if ssh_cidr == '0.0.0.0/0'
              raise ArgumentError, "ssh_cidr must not be 0.0.0.0/0 — SSH must not be public"
            end
            if api_cidr == '0.0.0.0/0'
              raise ArgumentError, "api_cidr must not be 0.0.0.0/0 — K8s API must not be public"
            end
          end

          # Security group rules — private ports restricted to VPC CIDR,
          # SSH restricted to VPC, only HTTP/HTTPS public for ingress.
          def aws_security_group_rules(config, vpc_cidr)
            ssh_cidr = config.tags[:ssh_cidr] || config.tags['ssh_cidr'] || vpc_cidr
            api_cidr = config.tags[:api_cidr] || config.tags['api_cidr'] || vpc_cidr

            base_firewall_ports(config.distribution).map do |port_name, port_def|
              cidr = case port_name
                     when :ssh then [ssh_cidr]
                     when :api then [api_cidr]
                     when :http, :https then ['0.0.0.0/0']
                     else [vpc_cidr]
                     end

              {
                from_port: port_range_start(port_def[:port]),
                to_port: port_range_end(port_def[:port]),
                protocol: port_def[:protocol].to_s,
                cidr_blocks: cidr,
                description: port_def[:description]
              }
            end
          end

          def port_range_start(port)
            port.is_a?(String) ? port.split('-').first.to_i : port
          end

          def port_range_end(port)
            port.is_a?(String) ? port.split('-').last.to_i : port
          end
        end
      end
    end
  end
end
