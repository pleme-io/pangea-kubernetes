# frozen_string_literal: true

# Type validation spec for aws_nixos backend.
#
# Uses TypedSynthesizerContext to run REAL dry-struct type validation
# from pangea-aws for every resource call. This catches bugs like:
# - assume_role_policy passed as JSON String instead of Hash
# - S3 encryption with aws:kms but missing kms_master_key_id
# - health_check.port as Integer instead of String
# - Security group using ingress/egress instead of ingress_rules/egress_rules
# - Launch template attributes not nested under launch_template_data
# - LB using subnets instead of subnet_ids
# - Route table using route instead of routes

require 'pangea-aws'

RSpec.describe 'aws_nixos backend type validation' do
  include SynthesisTestHelpers
  include TypedContextHelpers

  let(:typed_ctx) { create_typed_aws_context }

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

    it 'creates VPC with lifecycle meta-argument' do
      result = Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result[:vpc]).not_to be_nil
    end

    it 'creates route table with routes (not route)' do
      result = Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result[:route_table]).not_to be_nil
    end

    it 'creates security group with ingress_rules and egress_rules' do
      result = Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(result[:sg]).not_to be_nil
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

    it 'creates IAM role with Hash assume_role_policy (not JSON String)' do
      iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
      expect(iam[:role]).not_to be_nil
    end

    it 'creates all 5 IAM policies with valid policy documents' do
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
      # This was the original bug: port: 6443 (Integer) instead of '6443' (String)
      ref = Pangea::Kubernetes::Backends::AwsNixos.create_cluster(
        typed_ctx, :typecheck, cluster_config, arch_result, base_tags
      )
      expect(ref).not_to be_nil
    end

    it 'validates launch template data is properly nested' do
      ref = Pangea::Kubernetes::Backends::AwsNixos.create_cluster(
        typed_ctx, :typecheck, cluster_config, arch_result, base_tags
      )
      expect(ref).to be_a(Pangea::Kubernetes::Backends::AwsNixos::ControlPlaneRef)
    end

    it 'validates NLB uses subnet_ids (not subnets)' do
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
  end
end
