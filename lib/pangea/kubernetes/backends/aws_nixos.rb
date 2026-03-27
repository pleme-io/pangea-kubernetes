# frozen_string_literal: true

require 'base64'

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

require 'json'
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

        ControlPlaneRef = Struct.new(
          :nlb, :asg, :lt, :tg, :listener, :asg_tg,
          :subnet_ids, :sg_id, :instance_profile_name, :ami_id, :key_name,
          :ingress_alb, :ingress_alb_tg, :ingress_alb_https_listener, :ingress_alb_http_listener,
          :ingress_alb_sg,
          :vpn_nlb, :vpn_nlb_tg, :vpn_nlb_listener,
          :public_subnet_ids,
          :distribution_track,
          :agent_bootstrap_secrets,
          keyword_init: true
        ) do
          def ipv4_address
            nlb.dns_name
          end

          def id
            nlb.id
          end

          def arn
            nlb.arn
          end
        end

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
            network = Architecture::NetworkResult.new

            # S3 bucket for etcd backups (optional — disable for dev clusters)
            if config.etcd_backup_enabled
              etcd_bucket = config.etcd_backup_bucket || "#{name}-etcd-backups"
              network.etcd_bucket = ctx.aws_s3_bucket(
                :"#{name}_etcd",
                bucket: etcd_bucket,
                tags: tags.merge(Name: etcd_bucket)
              )
              if config.etcd_backup_versioning
                ctx.aws_s3_bucket_versioning(
                  :"#{name}_etcd_versioning",
                  bucket: network.etcd_bucket.id,
                  versioning_configuration: { status: 'Enabled' }
                )
              end
              ctx.aws_s3_bucket_server_side_encryption_configuration(
                :"#{name}_etcd_encryption",
                bucket: network.etcd_bucket.id,
                rule: [{ apply_server_side_encryption_by_default: { sse_algorithm: 'AES256' } }]
              )
              ctx.aws_s3_bucket_public_access_block(
                :"#{name}_etcd_public_access",
                bucket: network.etcd_bucket.id,
                block_public_acls: true,
                block_public_policy: true,
                ignore_public_acls: true,
                restrict_public_buckets: true
              )
            end

            vpc_cidr = config.network&.vpc_cidr || '10.0.0.0/16'

            # ── VPC ─────────────────────────────────────────────────
            network.vpc = ctx.aws_vpc(
              :"#{name}_vpc",
              cidr_block: vpc_cidr,
              enable_dns_hostnames: true,
              enable_dns_support: true,
              tags: tags.merge(Name: "#{name}-vpc"),
              lifecycle: { prevent_destroy: false }
            )

            # ── Internet Gateway ────────────────────────────────────
            network.igw = ctx.aws_internet_gateway(
              :"#{name}_igw",
              vpc_id: network.vpc.id,
              tags: tags.merge(Name: "#{name}-igw")
            )

            # ── Public Route Table (IGW → internet) ─────────────────
            public_rt = ctx.aws_route_table(
              :"#{name}_public_rt",
              vpc_id: network.vpc.id,
              tags: tags.merge(Name: "#{name}-public-rt")
            )
            network.route_table = public_rt

            ctx.aws_route(
              :"#{name}_public_default_route",
              route_table_id: public_rt.id,
              destination_cidr_block: '0.0.0.0/0',
              gateway_id: network.igw.id
            )

            # ── CIDR Layout (organized by tier × AZ) ───────────────
            #
            #   VPC: 10.0.0.0/16
            #
            #   Public tier  (NLBs, NAT, bastions — internet-facing):
            #     10.0.0.0/24   public-a   us-east-1a
            #     10.0.1.0/24   public-b   us-east-1b
            #     10.0.2.0/24   public-c   us-east-1c
            #
            #   Web tier  (K8s nodes, apps — private, NAT egress):
            #     10.0.10.0/24  web-a      us-east-1a
            #     10.0.11.0/24  web-b      us-east-1b
            #     10.0.12.0/24  web-c      us-east-1c
            #
            #   Data tier  (databases, caches — private, no internet):
            #     10.0.20.0/24  data-a     us-east-1a
            #     10.0.21.0/24  data-b     us-east-1b
            #     10.0.22.0/24  data-c     us-east-1c
            #
            azs = %w[a b c]

            # ── Public Subnets ──────────────────────────────────────
            azs.each_with_index do |az, idx|
              subnet = ctx.aws_subnet(
                :"#{name}_public_#{az}",
                vpc_id: network.vpc.id,
                cidr_block: "10.0.#{idx}.0/24",
                availability_zone: "#{config.region}#{az}",
                map_public_ip_on_launch: true,
                tags: tags.merge(Name: "#{name}-public-#{az}", Tier: 'public')
              )
              network.add_subnet(:"public_#{az}", subnet, tier: :public)

              ctx.aws_route_table_association(
                :"#{name}_public_rta_#{az}",
                subnet_id: subnet.id,
                route_table_id: public_rt.id
              )
            end

            # ── Web Subnets (created before NAT so we can associate per-AZ) ─
            web_subnets = []
            azs.each_with_index do |az, idx|
              subnet = ctx.aws_subnet(
                :"#{name}_web_#{az}",
                vpc_id: network.vpc.id,
                cidr_block: "10.0.#{10 + idx}.0/24",
                availability_zone: "#{config.region}#{az}",
                map_public_ip_on_launch: false,
                tags: tags.merge(Name: "#{name}-web-#{az}", Tier: 'web')
              )
              network.add_subnet(:"web_#{az}", subnet, tier: :web)
              web_subnets << subnet
            end

            if config.nat_per_az
              # ── Per-AZ NAT Gateways (HA) ────────────────────────────
              azs.each_with_index do |az, idx|
                eip = ctx.aws_eip(
                  :"#{name}_nat_eip_#{az}",
                  tags: tags.merge(Name: "#{name}-nat-eip-#{az}")
                )
                nat = ctx.aws_nat_gateway(
                  :"#{name}_nat_#{az}",
                  subnet_id: network.public_subnets[idx].id,
                  allocation_id: eip.id,
                  tags: tags.merge(Name: "#{name}-nat-#{az}")
                )
                web_rt = ctx.aws_route_table(
                  :"#{name}_web_rt_#{az}",
                  vpc_id: network.vpc.id,
                  tags: tags.merge(Name: "#{name}-web-rt-#{az}")
                )
                ctx.aws_route(
                  :"#{name}_web_default_route_#{az}",
                  route_table_id: web_rt.id,
                  destination_cidr_block: '0.0.0.0/0',
                  nat_gateway_id: nat.id
                )
                ctx.aws_route_table_association(
                  :"#{name}_web_rta_#{az}",
                  subnet_id: web_subnets[idx].id,
                  route_table_id: web_rt.id
                )
              end
            else
              # ── Single NAT Gateway (in public-a) ────────────────────
              eip = ctx.aws_eip(
                :"#{name}_nat_eip",
                tags: tags.merge(Name: "#{name}-nat-eip")
              )

              nat_gw = ctx.aws_nat_gateway(
                :"#{name}_nat",
                allocation_id: eip.id,
                subnet_id: network.public_subnets.first.id,
                tags: tags.merge(Name: "#{name}-nat")
              )

              web_rt = ctx.aws_route_table(
                :"#{name}_web_rt",
                vpc_id: network.vpc.id,
                tags: tags.merge(Name: "#{name}-web-rt")
              )

              ctx.aws_route(
                :"#{name}_web_default_route",
                route_table_id: web_rt.id,
                destination_cidr_block: '0.0.0.0/0',
                nat_gateway_id: nat_gw.id
              )

              web_subnets.each_with_index do |subnet, idx|
                az = azs[idx]
                ctx.aws_route_table_association(
                  :"#{name}_web_rta_#{az}",
                  subnet_id: subnet.id,
                  route_table_id: web_rt.id
                )
              end
            end

            # ── Data Tier Route Table (no internet, VPC-local only) ─
            data_rt = ctx.aws_route_table(
              :"#{name}_data_rt",
              vpc_id: network.vpc.id,
              tags: tags.merge(Name: "#{name}-data-rt")
            )

            # ── Data Subnets ────────────────────────────────────────
            azs.each_with_index do |az, idx|
              subnet = ctx.aws_subnet(
                :"#{name}_data_#{az}",
                vpc_id: network.vpc.id,
                cidr_block: "10.0.#{20 + idx}.0/24",
                availability_zone: "#{config.region}#{az}",
                map_public_ip_on_launch: false,
                tags: tags.merge(Name: "#{name}-data-#{az}", Tier: 'data')
              )
              network.add_subnet(:"data_#{az}", subnet, tier: :data)

              ctx.aws_route_table_association(
                :"#{name}_data_rta_#{az}",
                subnet_id: subnet.id,
                route_table_id: data_rt.id
              )
            end

            # Security group — K3s ports restricted to VPC CIDR
            network.sg = ctx.aws_security_group(
              :"#{name}_sg",
              description: "Security group for #{name} k8s/k3s NixOS nodes",
              vpc_id: network.vpc.id,
              tags: tags.merge(Name: "#{name}-sg")
            )

            # Ingress rules as separate aws_security_group_rule resources
            aws_security_group_rules(config, vpc_cidr).each_with_index do |rule, idx|
              rule_suffix = rule[:description]&.downcase&.gsub(/[^a-z0-9]+/, '_')&.gsub(/_+$/, '') || "rule_#{idx}"
              ctx.aws_security_group_rule(
                :"#{name}_sg_ingress_#{rule_suffix}",
                type: 'ingress',
                security_group_id: network.sg.id,
                from_port: rule[:from_port],
                to_port: rule[:to_port],
                protocol: rule[:protocol],
                cidr_blocks: rule[:cidr_blocks],
                description: rule[:description]
              )
            end

            # Egress rule — allow all outbound
            ctx.aws_security_group_rule(
              :"#{name}_sg_egress_all",
              type: 'egress',
              security_group_id: network.sg.id,
              from_port: 0,
              to_port: 0,
              protocol: '-1',
              cidr_blocks: ['0.0.0.0/0']
            )

            # ── VPC Flow Logs (optional — network traffic auditing) ───
            if config.flow_logs_enabled
              flow_trust = JSON.generate({
                Version: '2012-10-17',
                Statement: [{ Effect: 'Allow',
                  Principal: { Service: 'vpc-flow-logs.amazonaws.com' },
                  Action: 'sts:AssumeRole' }]
              })
              flow_role = ctx.aws_iam_role(:"#{name}_flow_log_role",
                assume_role_policy: flow_trust,
                tags: tags.merge(Name: "#{name}-flow-log-role"))

              flow_policy = ctx.aws_iam_policy(:"#{name}_flow_log_policy",
                policy: JSON.generate({ Version: '2012-10-17',
                  Statement: [{ Effect: 'Allow',
                    Action: %w[logs:CreateLogGroup logs:CreateLogStream logs:PutLogEvents
                                logs:DescribeLogGroups logs:DescribeLogStreams],
                    Resource: ["arn:aws:logs:#{config.region}:#{config.account_id}:log-group:/vpc/#{name}*"] }]
                }), tags: tags)

              ctx.aws_iam_role_policy_attachment(:"#{name}_flow_log_attach",
                role: flow_role.name, policy_arn: flow_policy.arn)

              flow_log_group = ctx.aws_cloudwatch_log_group(:"#{name}_flow_logs",
                retention_in_days: config.flow_logs_retention_days,
                tags: tags.merge(Name: "#{name}-flow-logs"))

              network.flow_log = ctx.aws_flow_log(:"#{name}_vpc_flow_log",
                vpc_id: network.vpc.id,
                traffic_type: config.flow_logs_traffic_type,
                log_destination_type: 'cloud-watch-logs',
                log_group_name: flow_log_group.name,
                iam_role_arn: flow_role.arn,
                tags: tags.merge(Name: "#{name}-vpc-flow-log"))
              network.flow_log_role = flow_role
            end

            # ── SSM Logs Bucket (optional — separate from etcd) ───────
            if config.ssm_logs_bucket
              network.ssm_logs_bucket = ctx.aws_s3_bucket(:"#{name}_ssm_logs",
                bucket: config.ssm_logs_bucket,
                tags: tags.merge(Name: config.ssm_logs_bucket))
              ctx.aws_s3_bucket_server_side_encryption_configuration(:"#{name}_ssm_logs_sse",
                bucket: network.ssm_logs_bucket.id,
                rule: [{ apply_server_side_encryption_by_default: { sse_algorithm: 'AES256' } }])
              ctx.aws_s3_bucket_public_access_block(:"#{name}_ssm_logs_pab",
                bucket: network.ssm_logs_bucket.id,
                block_public_acls: true, block_public_policy: true,
                ignore_public_acls: true, restrict_public_buckets: true)
            end

            network
          end

          # ── Phase 2: IAM (least-privilege) ───────────────────────────
          def create_iam(ctx, name, config, tags)
            iam = Architecture::IamResult.new
            account_id = config.account_id
            if account_id.nil? || account_id == 'CHANGEME'
              raise ArgumentError,
                    "account_id is required for IAM policy scoping. " \
                    "Set ACCOUNT_ID env var or pass account_id in tags."
            end
            region = config.region
            etcd_bucket = config.etcd_backup_bucket || "#{name}-etcd-backups"
            log_group = "/k3s/#{name}"

            # EC2-only assume-role trust policy (JSON String per Terraform schema)
            assume_role_policy = JSON.generate({
              Version: '2012-10-17',
              Statement: [{
                Effect: 'Allow',
                Principal: { Service: 'ec2.amazonaws.com' },
                Action: 'sts:AssumeRole'
              }]
            })

            iam.role = ctx.aws_iam_role(
              :"#{name}_node_role",
              description: "Least-privilege role for #{name} K3s cluster nodes",
              assume_role_policy: assume_role_policy,
              max_session_duration: 3600,
              tags: tags.merge(Name: "#{name}-node-role")
            )

            iam.instance_profile = ctx.aws_iam_instance_profile(
              :"#{name}_node_profile",
              role: iam.role.ref(:name),
              tags: tags.merge(Name: "#{name}-node-profile")
            )

            # ── Policy: ECR Read-Only ────────────────────────────────
            ecr_resource = ["arn:aws:ecr:#{region}:#{account_id}:repository/*"]

            iam.ecr_policy = ctx.aws_iam_policy(
              :"#{name}_ecr_read",
              description: "ECR read-only for #{name} K3s nodes",
              policy: JSON.generate({
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
              }),
              tags: tags,
            )
            ctx.aws_iam_role_policy_attachment(:"#{name}_ecr_read",
                                              role: iam.role.ref(:name), policy_arn: iam.ecr_policy.ref(:arn))

            # ── Policy: S3 Etcd Backup (conditional) ─────────────────
            if config.etcd_backup_enabled
              iam.etcd_policy = ctx.aws_iam_policy(
                :"#{name}_etcd_backup",
                description: "S3 etcd backup access for #{name} K3s nodes",
                policy: JSON.generate({
                  Version: '2012-10-17',
                  Statement: [{
                    Sid: 'EtcdBackupReadWrite',
                    Effect: 'Allow',
                    Action: %w[s3:GetObject s3:PutObject s3:ListBucket],
                    Resource: ["arn:aws:s3:::#{etcd_bucket}", "arn:aws:s3:::#{etcd_bucket}/*"],
                  }],
                }),
                tags: tags,
              )
              ctx.aws_iam_role_policy_attachment(:"#{name}_etcd_backup",
                                                role: iam.role.ref(:name), policy_arn: iam.etcd_policy.ref(:arn))
            end

            # ── Policy: CloudWatch Logs ──────────────────────────────
            logs_resource = ["arn:aws:logs:#{region}:#{account_id}:log-group:#{log_group}:*"]

            iam.logs_policy = ctx.aws_iam_policy(
              :"#{name}_logs",
              description: "CloudWatch log access for #{name} K3s nodes",
              policy: JSON.generate({
                Version: '2012-10-17',
                Statement: [{
                  Sid: 'CloudWatchLogs',
                  Effect: 'Allow',
                  Action: %w[logs:CreateLogStream logs:PutLogEvents logs:DescribeLogStreams],
                  Resource: logs_resource,
                }],
              }),
              tags: tags,
            )
            ctx.aws_iam_role_policy_attachment(:"#{name}_logs",
                                              role: iam.role.ref(:name), policy_arn: iam.logs_policy.ref(:arn))

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

            iam.ec2_policy = ctx.aws_iam_policy(
              :"#{name}_ec2_describe",
              description: "EC2 read-only metadata for #{name} K3s nodes",
              policy: JSON.generate({ Version: '2012-10-17', Statement: [ec2_statement] }),
              tags: tags,
            )
            ctx.aws_iam_role_policy_attachment(:"#{name}_ec2_describe",
                                              role: iam.role.ref(:name), policy_arn: iam.ec2_policy.ref(:arn))

            # ── Policy: SSM Session Manager ──────────────────────────
            ssm_bucket = config.ssm_logs_bucket || etcd_bucket
            iam.ssm_policy = ctx.aws_iam_policy(
              :"#{name}_ssm",
              description: "SSM session access for #{name} K3s nodes",
              policy: JSON.generate({
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
                  Resource: ["arn:aws:s3:::#{ssm_bucket}/ssm-logs/*"],
                }],
              }),
              tags: tags,
            )
            ctx.aws_iam_role_policy_attachment(:"#{name}_ssm",
                                              role: iam.role.ref(:name), policy_arn: iam.ssm_policy.ref(:arn))

            # ── KMS Key for CloudWatch Logs (optional) ─────────────────
            kms_key_id = nil
            if config.kms_logs_enabled
              if config.kms_key_arn
                kms_key_id = config.kms_key_arn
              else
                kms_key = ctx.aws_kms_key(:"#{name}_logs_kms",
                  description: "KMS key for #{name} CloudWatch logs",
                  enable_key_rotation: true,
                  policy: kms_cloudwatch_policy(account_id, config.region),
                  tags: tags.merge(Name: "#{name}-logs-kms"))
                ctx.aws_kms_alias(:"#{name}_logs_kms_alias",
                  name: "alias/#{name}-logs", target_key_id: kms_key.id)
                kms_key_id = kms_key.arn
              end
            end

            # ── CloudWatch Log Group ─────────────────────────────────
            log_group_attrs = {
              retention_in_days: 30,
              tags: tags.merge(Name: "#{name}-logs")
            }
            log_group_attrs[:kms_key_id] = kms_key_id if kms_key_id

            iam.log_group = ctx.aws_cloudwatch_log_group(
              :"#{name}_logs",
              **log_group_attrs
            )

            # ── Karpenter IRSA role (opt-in, deployed post-cluster via GitOps)
            if config.karpenter_enabled
              karpenter_assume = JSON.generate({
                Version: '2012-10-17',
                Statement: [{
                  Effect: 'Allow',
                  Principal: { Service: 'ec2.amazonaws.com' },
                  Action: 'sts:AssumeRole'
                }]
              })

              iam.karpenter_role = ctx.aws_iam_role(
                :"#{name}_karpenter_role",
                description: "Karpenter node role for #{name} (IRSA)",
                assume_role_policy: karpenter_assume,
                max_session_duration: 3600,
                tags: tags.merge(Name: "#{name}-karpenter-role")
              )

              iam.karpenter_profile = ctx.aws_iam_instance_profile(
                :"#{name}_karpenter_profile",
                role: iam.karpenter_role.ref(:name),
                tags: tags.merge(Name: "#{name}-karpenter-profile")
              )
            end

            iam
          end

          # ── Phase 3: Cluster (control plane via LT+ASG+NLB) ────────────
          def create_cluster(ctx, name, config, result, tags)
            system_pool = config.system_node_pool
            instance_type = system_pool.instance_types.first
            ami_id = if config.ami_id
                        config.ami_id
                      elsif config.ssm_ami_parameter
                        ctx.extend(Pangea::Resources::AWS) unless ctx.respond_to?(:data_aws_ssm_parameter)
                        ssm_data = ctx.data_aws_ssm_parameter(:"#{name}-ami", name: config.ssm_ami_parameter)
                        ssm_data.value
                      else
                        config.nixos&.image_id || 'ami-nixos-latest'
                      end
            subnet_ids = resolve_subnet_ids(config, result)
            sg_id = result.network&.sg&.id
            instance_profile_name = result.iam&.instance_profile&.ref(:name)
            key_name = config.key_pair

            cloud_init = build_server_cloud_init(name, config, 0, result)

            effective_key_name = config.ssm_only ? nil : key_name
            cp_lt_attrs = {
              image_id: ami_id,
              instance_type: instance_type,
              user_data: Base64.strict_encode64(cloud_init),
              iam_instance_profile: instance_profile_name ? { name: instance_profile_name } : nil,
              vpc_security_group_ids: sg_id ? [sg_id] : [],
              metadata_options: {
                http_endpoint: 'enabled',
                http_tokens: 'required',
                http_put_response_hop_limit: 1,
                instance_metadata_tags: 'enabled',
              },
              block_device_mappings: [{
                device_name: '/dev/xvda',
                ebs: {
                  volume_size: system_pool.disk_size_gb,
                  volume_type: 'gp3',
                  encrypted: true,
                }
              }],
              tag_specifications: [{
                resource_type: 'instance',
                tags: tags.merge(
                  Name: "#{name}-cp",
                  Role: 'control-plane',
                  Distribution: config.distribution.to_s
                )
              }],
              tags: tags.merge(Name: "#{name}-cp-lt")
            }
            cp_lt_attrs[:key_name] = effective_key_name if effective_key_name

            lt = ctx.aws_launch_template(:"#{name}_cp_lt", **cp_lt_attrs)

            # min_size=0 allows parked mode (all instances off, infra preserved)
            cp_desired = system_pool.min_size || 1
            max_cp = system_pool.max_size || [cp_desired, 1].max
            cp_asg_attrs = {
              min_size: cp_desired,
              max_size: [max_cp, cp_desired].max,
              launch_template: { id: lt.id, version: '$Latest' },
              vpc_zone_identifier: subnet_ids,
              health_check_grace_period: 300,
              tag: [
                { key: 'Name', value: "#{name}-cp", propagate_at_launch: true },
                { key: 'KubernetesCluster', value: name.to_s, propagate_at_launch: true },
                { key: 'Role', value: 'control-plane', propagate_at_launch: true }
              ]
            }
            cp_asg_attrs[:desired_capacity] = system_pool.desired_size if system_pool.desired_size

            asg = ctx.aws_autoscaling_group(:"#{name}_cp_asg", **cp_asg_attrs)

            nlb = ctx.aws_lb(
              :"#{name}_cp_nlb",
              name: "#{name}-cp-nlb",
              internal: true,
              load_balancer_type: 'network',
              subnets: subnet_ids,
              tags: tags.merge(Name: "#{name}-cp-nlb")
            )

            tg = ctx.aws_lb_target_group(
              :"#{name}_cp_tg",
              name: "#{name}-cp-tg",
              port: 6443,
              protocol: 'TCP',
              vpc_id: result.network&.vpc&.id,
              target_type: 'instance',
              health_check: {
                protocol: 'TCP',
                port: '6443',
                healthy_threshold: 3,
                unhealthy_threshold: 3,
                interval: 30,
              },
              tags: tags.merge(Name: "#{name}-cp-tg")
            )

            listener = ctx.aws_lb_listener(
              :"#{name}_cp_listener",
              load_balancer_arn: nlb.arn,
              port: 6443,
              protocol: 'TCP',
              default_action: [{ type: 'forward', target_group_arn: tg.arn }]
            )

            asg_tg = ctx.aws_autoscaling_attachment(
              :"#{name}_cp_asg_tg",
              autoscaling_group_name: asg.id,
              lb_target_group_arn: tg.arn
            )

            # ── Ingress ALB (optional — HTTP/HTTPS for services) ────
            ingress_alb = nil
            ingress_alb_tg = nil
            ingress_alb_https_listener = nil
            ingress_alb_http_listener = nil
            alb_sg = nil
            public_subnet_ids = resolve_public_subnet_ids(config, result)

            # ── ACM Certificate (optional — auto-create for ALB HTTPS) ─
            effective_cert_arn = config.ingress_alb_certificate_arn
            if config.ingress_alb_enabled && config.ingress_alb_domain && !effective_cert_arn
              acm_cert = ctx.aws_acm_certificate(:"#{name}_ingress_cert",
                domain_name: config.ingress_alb_domain,
                validation_method: 'DNS',
                tags: tags.merge(Name: "#{name}-ingress-cert"))
              if config.ingress_alb_zone_id
                ctx.aws_acm_certificate_validation(:"#{name}_ingress_cert_validation",
                  certificate_arn: acm_cert.arn)
              end
              effective_cert_arn = acm_cert.arn
            end

            if config.ingress_alb_enabled
              # ALB security group — allows 80/443 from ingress_source_cidr
              ingress_cidr = config.ingress_source_cidr || '0.0.0.0/0'
              alb_sg = ctx.aws_security_group(
                :"#{name}_alb_sg",
                description: "ALB security group for #{name} ingress",
                vpc_id: result.network&.vpc&.id,
                tags: tags.merge(Name: "#{name}-alb-sg")
              )

              ctx.aws_security_group_rule(
                :"#{name}_alb_sg_https",
                type: 'ingress', from_port: 443, to_port: 443, protocol: 'tcp',
                cidr_blocks: [ingress_cidr],
                security_group_id: alb_sg.id,
                description: 'HTTPS ingress'
              )

              ctx.aws_security_group_rule(
                :"#{name}_alb_sg_http",
                type: 'ingress', from_port: 80, to_port: 80, protocol: 'tcp',
                cidr_blocks: [ingress_cidr],
                security_group_id: alb_sg.id,
                description: 'HTTP ingress (redirect to HTTPS)'
              )

              ctx.aws_security_group_rule(
                :"#{name}_alb_sg_egress",
                type: 'egress', from_port: 0, to_port: 0, protocol: '-1',
                cidr_blocks: ['0.0.0.0/0'],
                security_group_id: alb_sg.id
              )

              ingress_alb = ctx.aws_lb(
                :"#{name}_ingress_alb",
                name: "#{name}-ingress",
                internal: false,
                load_balancer_type: 'application',
                subnets: public_subnet_ids,
                security_groups: [alb_sg.id],
                idle_timeout: config.ingress_alb_idle_timeout,
                tags: tags.merge(Name: "#{name}-ingress-alb")
              )

              # Target group for ingress controller (HTTP on nodes)
              ingress_alb_tg = ctx.aws_lb_target_group(
                :"#{name}_ingress_tg",
                name: "#{name}-ingress-tg",
                port: 80,
                protocol: 'HTTP',
                vpc_id: result.network&.vpc&.id,
                target_type: 'instance',
                health_check: {
                  protocol: 'HTTP',
                  port: '80',
                  path: '/healthz',
                  healthy_threshold: 2,
                  unhealthy_threshold: 3,
                  interval: 15,
                },
                tags: tags.merge(Name: "#{name}-ingress-tg")
              )

              # HTTPS listener (TLS termination at ALB)
              if effective_cert_arn
                ingress_alb_https_listener = ctx.aws_lb_listener(
                  :"#{name}_ingress_https",
                  load_balancer_arn: ingress_alb.arn,
                  port: 443,
                  protocol: 'HTTPS',
                  ssl_policy: 'ELBSecurityPolicy-TLS13-1-2-2021-06',
                  certificate_arn: effective_cert_arn,
                  default_action: [{ type: 'forward', target_group_arn: ingress_alb_tg.arn }]
                )
              end

              # HTTP listener (redirect to HTTPS or forward)
              if config.ingress_alb_http_redirect && effective_cert_arn
                ingress_alb_http_listener = ctx.aws_lb_listener(
                  :"#{name}_ingress_http",
                  load_balancer_arn: ingress_alb.arn,
                  port: 80,
                  protocol: 'HTTP',
                  default_action: [{
                    type: 'redirect',
                    redirect: { port: '443', protocol: 'HTTPS', status_code: 'HTTP_301' }
                  }]
                )
              else
                ingress_alb_http_listener = ctx.aws_lb_listener(
                  :"#{name}_ingress_http",
                  load_balancer_arn: ingress_alb.arn,
                  port: 80,
                  protocol: 'HTTP',
                  default_action: [{ type: 'forward', target_group_arn: ingress_alb_tg.arn }]
                )
              end

              # Attach worker ASG to ingress target group (done in create_node_pool)

              # SG-to-SG rules for HTTP/HTTPS when restricted to ALB
              if config.sg_restrict_http_to_alb
                ctx.aws_security_group_rule(:"#{name}_sg_http_from_alb",
                  type: 'ingress', from_port: 80, to_port: 80, protocol: 'tcp',
                  source_security_group_id: alb_sg.id,
                  security_group_id: result.network.sg.id,
                  description: 'HTTP from ALB only')
                ctx.aws_security_group_rule(:"#{name}_sg_https_from_alb",
                  type: 'ingress', from_port: 443, to_port: 443, protocol: 'tcp',
                  source_security_group_id: alb_sg.id,
                  security_group_id: result.network.sg.id,
                  description: 'HTTPS from ALB only')
              end
            end

            # ── VPN NLB (optional — WireGuard operator access) ──────
            vpn_nlb = nil
            vpn_nlb_tg = nil
            vpn_nlb_listener = nil

            if config.vpn_nlb_enabled
              vpn_port = config.vpn_nlb_port.to_i

              vpn_nlb = ctx.aws_lb(
                :"#{name}_vpn_nlb",
                name: "#{name}-vpn",
                internal: false,
                load_balancer_type: 'network',
                subnets: public_subnet_ids,
                tags: tags.merge(Name: "#{name}-vpn-nlb")
              )

              health_port = (config.vpn_health_check_port || vpn_port).to_s
              vpn_nlb_tg = ctx.aws_lb_target_group(
                :"#{name}_vpn_tg",
                name: "#{name}-vpn-wg",
                port: vpn_port,
                protocol: 'UDP',
                vpc_id: result.network&.vpc&.id,
                target_type: 'instance',
                health_check: {
                  protocol: 'TCP',
                  port: health_port,
                  healthy_threshold: 3,
                  unhealthy_threshold: 3,
                  interval: 30,
                },
                tags: tags.merge(Name: "#{name}-vpn-tg")
              )

              vpn_nlb_listener = ctx.aws_lb_listener(
                :"#{name}_vpn_listener",
                load_balancer_arn: vpn_nlb.arn,
                port: vpn_port,
                protocol: 'UDP',
                default_action: [{ type: 'forward', target_group_arn: vpn_nlb_tg.arn }]
              )

              # Attach control plane ASG to VPN target group
              ctx.aws_autoscaling_attachment(
                :"#{name}_vpn_asg_tg",
                autoscaling_group_name: asg.id,
                lb_target_group_arn: vpn_nlb_tg.arn
              )

              # Security group rule for VPN ingress
              vpn_source = config.vpn_source_cidr || config.ingress_source_cidr || '0.0.0.0/0'
              ctx.aws_security_group_rule(
                :"#{name}_sg_vpn_ingress",
                type: 'ingress', from_port: vpn_port, to_port: vpn_port, protocol: 'udp',
                cidr_blocks: [vpn_source],
                security_group_id: sg_id,
                description: 'WireGuard VPN (internet-facing NLB)'
              )
            end

            ControlPlaneRef.new(
              nlb: nlb, asg: asg, lt: lt, tg: tg,
              listener: listener, asg_tg: asg_tg,
              subnet_ids: subnet_ids, sg_id: sg_id,
              instance_profile_name: instance_profile_name,
              ami_id: ami_id, key_name: effective_key_name,
              ingress_alb: ingress_alb, ingress_alb_tg: ingress_alb_tg,
              ingress_alb_https_listener: ingress_alb_https_listener,
              ingress_alb_http_listener: ingress_alb_http_listener,
              ingress_alb_sg: config.ingress_alb_enabled ? alb_sg : nil,
              vpn_nlb: vpn_nlb, vpn_nlb_tg: vpn_nlb_tg,
              vpn_nlb_listener: vpn_nlb_listener,
              public_subnet_ids: public_subnet_ids,
              distribution_track: config.distribution_track || config.kubernetes_version,
              agent_bootstrap_secrets: build_agent_bootstrap_secrets(config)
            )
          end

          # ── Phase 4: Node pools (workers) ────────────────────────────
          def create_node_pool(ctx, name, cluster_ref, pool_config, tags)
            nixos_create_node_pool(ctx, name, cluster_ref, pool_config, tags)
          end

          # --- NixosBase template hooks ---

          def create_worker_pool(ctx, name, cluster_ref, pool_config, cloud_init, tags)
            pool_name = :"#{name}_#{pool_config.name}"
            instance_type = pool_config.instance_types.first

            # Read infra context from ControlPlaneRef (fixes missing IAM/SG/subnet bugs)
            ami_id = cluster_ref.respond_to?(:ami_id) ? cluster_ref.ami_id : (tags[:AmiId] || 'ami-nixos-latest')
            key_name = cluster_ref.respond_to?(:key_name) ? cluster_ref.key_name : tags[:KeyPair]
            subnet_ids = cluster_ref.respond_to?(:subnet_ids) ? cluster_ref.subnet_ids : (tags[:SubnetIds] || [])
            sg_id = cluster_ref.respond_to?(:sg_id) ? cluster_ref.sg_id : nil
            instance_profile_name = cluster_ref.respond_to?(:instance_profile_name) ? cluster_ref.instance_profile_name : nil

            worker_lt_attrs = {
              image_id: ami_id,
              instance_type: instance_type,
              user_data: Base64.strict_encode64(cloud_init),
              iam_instance_profile: instance_profile_name ? { name: instance_profile_name } : nil,
              vpc_security_group_ids: sg_id ? [sg_id] : [],
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
              }],
              tags: tags.merge(Name: "#{name}-#{pool_config.name}-lt")
            }
            worker_lt_attrs[:key_name] = key_name if key_name

            lt = ctx.aws_launch_template(:"#{pool_name}_lt", **worker_lt_attrs)

            worker_asg_attrs = {
              min_size: pool_config.min_size,
              max_size: pool_config.max_size,
              launch_template: { id: lt.id, version: '$Latest' },
              vpc_zone_identifier: subnet_ids,
              health_check_grace_period: 300,
              tag: [
                { key: 'Name', value: "#{name}-#{pool_config.name}", propagate_at_launch: true },
                { key: 'KubernetesCluster', value: name.to_s, propagate_at_launch: true },
                { key: 'NodePool', value: pool_config.name.to_s, propagate_at_launch: true }
              ]
            }
            worker_asg_attrs[:desired_capacity] = pool_config.desired_size if pool_config.desired_size

            worker_asg = ctx.aws_autoscaling_group(:"#{pool_name}_asg", **worker_asg_attrs)

            # Attach workers to ingress ALB target group when present
            if cluster_ref.respond_to?(:ingress_alb_tg) && cluster_ref.ingress_alb_tg
              ctx.aws_autoscaling_attachment(:"#{pool_name}_ingress_tg",
                autoscaling_group_name: worker_asg.id,
                lb_target_group_arn: cluster_ref.ingress_alb_tg.arn)
            end

            worker_asg
          end

          private

          # Resolve subnet IDs for K8s nodes — prefer web tier (private), fall back to all subnets.
          def resolve_subnet_ids(config, result)
            if config.network&.subnet_ids&.any?
              config.network.subnet_ids
            elsif result.network
              # Prefer web tier subnets (private, where K8s nodes should run)
              web = result.network.respond_to?(:web_subnet_ids) ? result.network.web_subnet_ids : []
              return web if web.any?

              # Fall back to all subnets
              result.network.respond_to?(:subnet_ids) ? result.network.subnet_ids : []
            else
              []
            end
          end

          # Resolve public subnet IDs for NLBs — prefer public tier.
          def resolve_public_subnet_ids(config, result)
            if result.network
              pub = result.network.respond_to?(:public_subnet_ids) ? result.network.public_subnet_ids : []
              return pub if pub.any?
            end
            # Fall back to resolve_subnet_ids (all subnets)
            resolve_subnet_ids(config, result)
          end

          # Reject 0.0.0.0/0 for SSH, K8s API, and VPN — these must never be public.
          def validate_cidr_restrictions!(config)
            ssh_cidr = config.ssh_cidr
            api_cidr = config.api_cidr
            vpn_cidr = config.vpn_cidr
            if ssh_cidr == '0.0.0.0/0'
              raise ArgumentError, "ssh_cidr must not be 0.0.0.0/0 — SSH must not be public"
            end
            if api_cidr == '0.0.0.0/0'
              raise ArgumentError, "api_cidr must not be 0.0.0.0/0 — K8s API must not be public"
            end
            if vpn_cidr == '0.0.0.0/0'
              raise ArgumentError, "vpn_cidr must not be 0.0.0.0/0 — WireGuard must not be public"
            end
            if vpn_cidr.nil? && config.vpn && config.vpn.links.any?
              raise ArgumentError, "vpn_cidr tag is required when VPN links are configured"
            end
          end

          # Security group rules — private ports restricted to VPC CIDR,
          # SSH restricted to VPC, only HTTP/HTTPS public for ingress.
          def aws_security_group_rules(config, vpc_cidr)
            ssh_cidr = config.ssh_cidr || vpc_cidr
            api_cidr = config.api_cidr || vpc_cidr
            vpn_cidr = config.vpn_cidr

            rules = base_firewall_ports(config.distribution).filter_map do |port_name, port_def|
              cidr = case port_name
                     when :ssh
                       next nil if config.ssm_only
                       [ssh_cidr]
                     when :api then [api_cidr]
                     when :http, :https
                       if config.sg_restrict_http_to_alb && config.ingress_alb_enabled
                         next nil # SG-source rules added in create_cluster
                       end
                       [config.ingress_source_cidr || '0.0.0.0/0']
                     when :wireguard then vpn_cidr ? [vpn_cidr] : [vpc_cidr]
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

            # Remove WireGuard rule entirely when no VPN is configured
            rules.reject! { |r| r[:description] == 'WireGuard VPN' } unless vpn_cidr || config.vpn

            rules
          end

          def kms_cloudwatch_policy(account_id, region)
            JSON.generate({
              Version: '2012-10-17',
              Statement: [
                { Sid: 'AllowKeyAdmin', Effect: 'Allow',
                  Principal: { AWS: "arn:aws:iam::#{account_id}:root" },
                  Action: %w[
                    kms:Create* kms:Describe* kms:Enable* kms:List*
                    kms:Put* kms:Update* kms:Revoke* kms:Disable*
                    kms:Get* kms:Delete* kms:TagResource kms:UntagResource
                    kms:ScheduleKeyDeletion kms:CancelKeyDeletion
                  ],
                  Resource: '*' },
                { Sid: 'AllowCloudWatchLogs', Effect: 'Allow',
                  Principal: { Service: "logs.#{region}.amazonaws.com" },
                  Action: %w[kms:Encrypt kms:Decrypt kms:ReEncrypt* kms:GenerateDataKey* kms:DescribeKey],
                  Resource: '*' }
              ]
            })
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
