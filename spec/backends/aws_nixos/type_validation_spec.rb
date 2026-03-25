# frozen_string_literal: true

# Type validation spec for aws_nixos backend.
#
# Uses TypedSynthesizerContext to run REAL dry-struct type validation
# from pangea-aws for every resource call. This catches bugs like:
# - assume_role_policy passed as Hash instead of JSON String
# - S3 encryption using wrong method name (aws_s3_bucket_encryption)
# - versioning_configuration as bare Hash instead of Array.of(Hash)
# - health_check as bare Hash instead of Array.of(Hash)
# - Security group rules as inline arrays instead of separate resources
# - Launch template attributes nested under launch_template_data instead of flat
# - LB using subnet_ids instead of subnets
# - Route table using inline routes instead of separate aws_route resources
# - IAM policy documents as Hash instead of JSON String

require 'pangea-aws'

RSpec.describe 'aws_nixos backend type validation' do
  include SynthesisTestHelpers
  include TypedContextHelpers

  let(:typed_ctx) { create_typed_aws_context }

  it_behaves_like 'typed backend contract',
    Pangea::Kubernetes::Backends::AwsNixos,
    :create_typed_aws_context

  let(:base_tags) { { KubernetesCluster: 'typecheck', Backend: 'aws_nixos', ManagedBy: 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :aws_nixos,
      kubernetes_version: '1.34',
      region: 'us-east-1',
      distribution: :k3s,
      profile: 'cilium-standard',
      distribution_track: '1.34',
      ami_id: 'ami-nixos-test',
      key_pair: 'typecheck-key',
      node_pools: [
        { name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1, disk_size_gb: 50 },
        { name: :workers, instance_types: ['t3.medium'], min_size: 1, max_size: 4, disk_size_gb: 50 }
      ],
      network: { vpc_cidr: '10.0.0.0/16' },
      tags: {
        account_id: '376129857990',
        etcd_backup_bucket: 'typecheck-etcd-backups',
        ssh_cidr: '10.0.0.0/8',
        api_cidr: '10.0.0.0/8',
      }
    )
  end

  # ── Phase 1: Network + Storage ────────────────────────────────

  describe '.create_network' do
    it 'passes type validation for all network resources' do
      expect {
        Pangea::Kubernetes::Backends::AwsNixos.create_network(
          typed_ctx, :typecheck, cluster_config, base_tags
        )
      }.not_to raise_error
    end

    it 'creates S3 bucket with valid encryption config' do
      result = Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result[:etcd_bucket]).not_to be_nil
    end

    it 'creates VPC' do
      result = Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result[:vpc]).not_to be_nil
    end

    it 'creates route table and separate aws_route for default route' do
      result = Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result[:route_table]).not_to be_nil
      route = typed_ctx.find_resource(:aws_route, :typecheck_default_route)
      expect(route).not_to be_nil
    end

    it 'creates security group with separate aws_security_group_rule resources' do
      result = Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result[:sg]).not_to be_nil
      sg_rules = typed_ctx.created_resources.select { |r| r[:type] == 'aws_security_group_rule' }
      expect(sg_rules).not_to be_empty
    end

    it 'uses aws_s3_bucket_server_side_encryption_configuration (not aws_s3_bucket_encryption)' do
      Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      sse = typed_ctx.find_resource(:aws_s3_bucket_server_side_encryption_configuration, :typecheck_etcd_encryption)
      expect(sse).not_to be_nil
    end
  end

  # ── Phase 2: IAM (least-privilege) ───────────────────────────

  describe '.create_iam' do
    it 'passes type validation for all IAM resources' do
      expect {
        Pangea::Kubernetes::Backends::AwsNixos.create_iam(
          typed_ctx, :typecheck, cluster_config, base_tags
        )
      }.not_to raise_error
    end

    it 'creates IAM role with JSON String assume_role_policy' do
      iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(iam[:role]).not_to be_nil
    end

    it 'creates all 5 IAM policies with JSON String policy documents' do
      iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(iam[:ecr_policy]).not_to be_nil
      expect(iam[:etcd_policy]).not_to be_nil
      expect(iam[:logs_policy]).not_to be_nil
      expect(iam[:ec2_policy]).not_to be_nil
      expect(iam[:ssm_policy]).not_to be_nil
    end

    context 'with karpenter_enabled' do
      let(:karpenter_config) do
        Pangea::Kubernetes::Types::ClusterConfig.new(
          backend: :aws_nixos, kubernetes_version: '1.34', region: 'us-east-1',
          distribution: :k3s, profile: 'cilium-standard', distribution_track: '1.34',
          ami_id: 'ami-nixos-test', key_pair: 'typecheck-key', karpenter_enabled: true,
          node_pools: [{ name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1, disk_size_gb: 50 }],
          network: { vpc_cidr: '10.0.0.0/16' },
          tags: { account_id: '376129857990', etcd_backup_bucket: 'typecheck-etcd' }
        )
      end

      it 'passes type validation for Karpenter IAM resources' do
        expect {
          Pangea::Kubernetes::Backends::AwsNixos.create_iam(
            typed_ctx, :typecheck, karpenter_config, base_tags
          )
        }.not_to raise_error
      end
    end
  end

  # ── Phase 3: Cluster (LT + ASG + NLB) ───────────────────────

  describe '.create_cluster' do
    let(:network) do
      Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
    end
    let(:iam) do
      Pangea::Kubernetes::Backends::AwsNixos.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
    end
    let(:arch_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:typecheck, cluster_config)
      r.network = network
      r.iam = iam
      r
    end

    it 'passes type validation for launch template, ASG, NLB, target group, and listener' do
      expect {
        Pangea::Kubernetes::Backends::AwsNixos.create_cluster(
          typed_ctx, :typecheck, cluster_config, arch_result, base_tags
        )
      }.not_to raise_error
    end

    it 'validates health_check.port as String (not Integer)' do
      ref = Pangea::Kubernetes::Backends::AwsNixos.create_cluster(
        typed_ctx, :typecheck, cluster_config, arch_result, base_tags
      )
      expect(ref).not_to be_nil
    end

    it 'validates launch template data is flat (not nested under launch_template_data)' do
      ref = Pangea::Kubernetes::Backends::AwsNixos.create_cluster(
        typed_ctx, :typecheck, cluster_config, arch_result, base_tags
      )
      expect(ref).to be_a(Pangea::Kubernetes::Backends::AwsNixos::ControlPlaneRef)
    end

    it 'validates NLB uses subnets (not subnet_ids)' do
      ref = Pangea::Kubernetes::Backends::AwsNixos.create_cluster(
        typed_ctx, :typecheck, cluster_config, arch_result, base_tags
      )
      expect(ref.nlb).not_to be_nil
    end
  end

  # ── Phase 4: Node Pools ──────────────────────────────────────

  describe '.create_node_pool' do
    let(:network) do
      Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
    end
    let(:iam) do
      Pangea::Kubernetes::Backends::AwsNixos.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
    end
    let(:arch_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:typecheck, cluster_config)
      r.network = network
      r.iam = iam
      r
    end
    let(:cluster_ref) do
      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(
        typed_ctx, :typecheck, cluster_config, arch_result, base_tags
      )
    end

    it 'passes type validation for worker launch template and ASG' do
      pool_config = cluster_config.node_pools.find { |p| p.name == :workers }
      expect {
        Pangea::Kubernetes::Backends::AwsNixos.create_node_pool(
          typed_ctx, :typecheck, cluster_ref, pool_config, base_tags
        )
      }.not_to raise_error
    end
  end

  # ── Full Pipeline ──────────────────────────────────────────────

  describe 'full pipeline' do
    it 'passes type validation for the complete kubernetes_cluster call' do
      synth = create_typed_aws_context
      synth.extend(Pangea::Kubernetes::Architecture)

      expect {
        synth.kubernetes_cluster(:typecheck, {
          backend: :aws_nixos,
          kubernetes_version: '1.34',
          region: 'us-east-1',
          distribution: :k3s,
          profile: 'cilium-standard',
          distribution_track: '1.34',
          ami_id: 'ami-nixos-test',
          key_pair: 'typecheck-key',
          node_pools: [
            { name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1, disk_size_gb: 50 },
          ],
          network: { vpc_cidr: '10.0.0.0/16' },
          tags: {
            account_id: '376129857990',
            etcd_backup_bucket: 'typecheck-etcd-backups',
            ssh_cidr: '10.0.0.0/8',
            api_cidr: '10.0.0.0/8',
          },
        })
      }.not_to raise_error
    end

    it 'passes type validation with VPN passthrough hash' do
      synth = create_typed_aws_context
      synth.extend(Pangea::Kubernetes::Architecture)

      expect {
        synth.kubernetes_cluster(:typecheck_vpn, {
          backend: :aws_nixos,
          kubernetes_version: '1.34',
          region: 'us-east-1',
          distribution: :k3s,
          profile: 'cilium-standard',
          distribution_track: '1.34',
          ami_id: 'ami-nixos-test',
          key_pair: 'typecheck-key',
          node_pools: [
            { name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1, disk_size_gb: 50 },
          ],
          network: { vpc_cidr: '10.0.0.0/16' },
          tags: {
            account_id: '376129857990',
            etcd_backup_bucket: 'typecheck-etcd-backups',
            ssh_cidr: '10.0.0.0/8',
            api_cidr: '10.0.0.0/8',
          },
          vpn: {
            interface: 'wg-test',
            address: '10.100.3.2/24',
            port: 51822,
          },
        })
      }.not_to raise_error
    end

    it 'passes type validation with FluxCD config' do
      synth = create_typed_aws_context
      synth.extend(Pangea::Kubernetes::Architecture)

      expect {
        synth.kubernetes_cluster(:typecheck_flux, {
          backend: :aws_nixos,
          kubernetes_version: '1.34',
          region: 'us-east-1',
          distribution: :k3s,
          profile: 'cilium-standard',
          distribution_track: '1.34',
          ami_id: 'ami-nixos-test',
          key_pair: 'typecheck-key',
          node_pools: [
            { name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1, disk_size_gb: 50 },
          ],
          network: { vpc_cidr: '10.0.0.0/16' },
          tags: {
            account_id: '376129857990',
            etcd_backup_bucket: 'typecheck-etcd-backups',
            ssh_cidr: '10.0.0.0/8',
            api_cidr: '10.0.0.0/8',
          },
          fluxcd: {
            source_url: 'https://github.com/org/k8s',
            source_branch: 'main',
            source_auth: 'token',
            reconcile_path: './clusters/test',
            sops_enabled: true,
          },
        })
      }.not_to raise_error
    end

    it 'passes type validation with multiple node pools' do
      synth = create_typed_aws_context
      synth.extend(Pangea::Kubernetes::Architecture)

      expect {
        synth.kubernetes_cluster(:typecheck_multi, {
          backend: :aws_nixos,
          kubernetes_version: '1.34',
          region: 'us-east-1',
          distribution: :k3s,
          profile: 'cilium-standard',
          distribution_track: '1.34',
          ami_id: 'ami-nixos-test',
          key_pair: 'typecheck-key',
          node_pools: [
            { name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 3, disk_size_gb: 50 },
            { name: :workers, instance_types: ['t3.large'], min_size: 2, max_size: 10, disk_size_gb: 100 },
            { name: :gpu, instance_types: ['c5.4xlarge'], min_size: 0, max_size: 4, disk_size_gb: 200 },
          ],
          network: { vpc_cidr: '10.0.0.0/16' },
          tags: {
            account_id: '376129857990',
            etcd_backup_bucket: 'typecheck-etcd-backups',
            ssh_cidr: '10.0.0.0/8',
            api_cidr: '10.0.0.0/8',
          },
        })
      }.not_to raise_error
    end

    it 'passes type validation for the full akeyless-dev-cluster scenario with VPN NLB' do
      synth = create_typed_aws_context
      synth.extend(Pangea::Kubernetes::Architecture)

      # Run the same kubernetes_cluster() call the akeyless-dev template makes
      result = synth.kubernetes_cluster(:akeyless_dev, {
        backend: :aws_nixos,
        kubernetes_version: '1.29',
        region: 'us-east-1',
        distribution: :k3s,
        profile: 'cilium-standard',
        ami_id: 'ami-nixos-test',
        key_pair: 'akeyless-dev-key',
        node_pools: [
          { name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1, disk_size_gb: 50 },
          { name: :worker, instance_types: ['t3.medium'], min_size: 1, max_size: 4, disk_size_gb: 50 },
        ],
        network: { vpc_cidr: '10.0.0.0/16' },
        tags: {
          account_id: '376129857990',
          etcd_backup_bucket: 'akeyless-dev-etcd-backups',
          ssh_cidr: '10.0.0.0/8',
          api_cidr: '10.0.0.0/8',
          vpn_cidr: '10.100.3.0/24',
        },
        vpn: {
          interface: 'wg-akeyless-dev',
          address: '10.100.3.2/24',
          port: 51822,
        },
        fluxcd: {
          source_url: 'https://github.com/pleme-io/akeyless-k8s',
          source_branch: 'main',
          source_auth: 'token',
          reconcile_path: './clusters/akeyless-dev',
          sops_enabled: true,
        },
      })

      # Verify typed ArchitectureResult contract
      expect(result).to be_a(Pangea::Kubernetes::Architecture::ArchitectureResult)
      expect(result.network).to be_a(Pangea::Kubernetes::Architecture::NetworkResult)
      expect(result.iam).to be_a(Pangea::Kubernetes::Architecture::IamResult)
      expect(result.cluster).to be_a(Pangea::Kubernetes::Architecture::ClusterResult)

      # Verify NetworkResult typed accessors
      expect(result.network.vpc).not_to be_nil
      expect(result.network.igw).not_to be_nil
      expect(result.network.route_table).not_to be_nil
      expect(result.network.sg).not_to be_nil
      expect(result.network.etcd_bucket).not_to be_nil
      expect(result.network.subnets).to be_an(Array)
      expect(result.network.subnets.length).to eq(2)
      expect(result.network.public_subnets).to eq(result.network.subnets)
      expect(result.network.subnet_ids).to be_an(Array)
      expect(result.network.subnet_ids.length).to eq(2)

      # Verify backward-compat hash access
      expect(result.network[:vpc]).to eq(result.network.vpc)
      expect(result.network[:sg]).to eq(result.network.sg)
      expect(result.network[:etcd_bucket]).to eq(result.network.etcd_bucket)

      # Verify IamResult typed accessors
      expect(result.iam.role).not_to be_nil
      expect(result.iam.instance_profile).not_to be_nil
      expect(result.iam.ecr_policy).not_to be_nil
      expect(result.iam.etcd_policy).not_to be_nil
      expect(result.iam.logs_policy).not_to be_nil
      expect(result.iam.ec2_policy).not_to be_nil
      expect(result.iam.ssm_policy).not_to be_nil
      expect(result.iam.log_group).not_to be_nil

      # Verify ClusterResult typed accessors
      expect(result.cluster.nlb).not_to be_nil
      expect(result.cluster.asg).not_to be_nil
      expect(result.cluster.launch_template).not_to be_nil
      expect(result.cluster.target_group).not_to be_nil
      expect(result.cluster.listener).not_to be_nil
      expect(result.cluster.security_group).not_to be_nil
      expect(result.cluster.security_group.id).not_to be_nil

      # Now exercise the VPN NLB resources (same calls as akeyless_dev_cluster.rb)
      expect {
        synth.aws_lb(:vpn_wireguard, {
          name: 'akeyless-dev-vpn',
          internal: false,
          load_balancer_type: 'network',
          subnets: result.network.subnet_ids,
          tags: { Name: 'akeyless-dev-vpn-nlb' },
        })
      }.not_to raise_error

      expect {
        synth.aws_lb_target_group(:vpn_wireguard, {
          name: 'akeyless-dev-vpn-wg',
          port: 51822,
          protocol: 'UDP',
          vpc_id: result.network.vpc.id,
          health_check: { protocol: 'TCP', port: '22' },
        })
      }.not_to raise_error

      vpn_nlb = synth.find_resource(:aws_lb, :vpn_wireguard)
      vpn_tg = synth.find_resource(:aws_lb_target_group, :vpn_wireguard)

      expect {
        synth.aws_lb_listener(:vpn_wireguard, {
          load_balancer_arn: vpn_nlb[:ref].arn,
          port: 51822,
          protocol: 'UDP',
          default_action: [{ type: 'forward', target_group_arn: vpn_tg[:ref].arn }],
        })
      }.not_to raise_error

      expect {
        synth.aws_autoscaling_attachment(:vpn_cp, {
          autoscaling_group_name: result.cluster.asg.ref(:name),
          lb_target_group_arn: vpn_tg[:ref].arn,
        })
      }.not_to raise_error
    end
  end

  # ── Typed ArchitectureResult Contract ──────────────────────────────

  describe 'ArchitectureResult typed contract' do
    it 'NetworkResult provides subnets array and public_subnets alias' do
      network = Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :contract, cluster_config, base_tags
      )
      expect(network).to be_a(Pangea::Kubernetes::Architecture::NetworkResult)
      expect(network.subnets.length).to eq(2)
      expect(network.public_subnets).to eq(network.subnets)
      expect(network.subnet_ids.all? { |id| id.is_a?(String) }).to be true
    end

    it 'IamResult provides named accessors for all policies' do
      iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(
        typed_ctx, :contract, cluster_config, base_tags
      )
      expect(iam).to be_a(Pangea::Kubernetes::Architecture::IamResult)
      expect(iam.role).not_to be_nil
      expect(iam.instance_profile).not_to be_nil
      expect(iam.log_group).not_to be_nil
    end

    it 'ClusterResult wraps ControlPlaneRef and exposes security_group' do
      network = Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :contract, cluster_config, base_tags
      )
      iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(
        typed_ctx, :contract, cluster_config, base_tags
      )
      arch = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:contract, cluster_config)
      arch.network = network
      arch.iam = iam
      cp_ref = Pangea::Kubernetes::Backends::AwsNixos.create_cluster(
        typed_ctx, :contract, cluster_config, arch, base_tags
      )
      # Setting cluster on ArchitectureResult wraps it in ClusterResult
      arch.cluster = cp_ref
      expect(arch.cluster).to be_a(Pangea::Kubernetes::Architecture::ClusterResult)
      expect(arch.cluster.nlb).to eq(cp_ref.nlb)
      expect(arch.cluster.asg).to eq(cp_ref.asg)
      expect(arch.cluster.security_group).to be_a(Pangea::Kubernetes::Architecture::SecurityGroupAccessor)
      expect(arch.cluster.security_group.id).not_to be_nil
    end
  end
end
