# frozen_string_literal: true

# Type validation spec for aws_nixos backend.
#
# Unlike cluster_synthesis_spec.rb which uses MockSynthesizerContext
# (bypasses real type validation), this spec validates that every
# resource call in the aws_nixos backend passes real dry-struct
# type validation from pangea-aws.
#
# This catches bugs like:
# - assume_role_policy passed as JSON String instead of Hash
# - S3 encryption with aws:kms but missing kms_master_key_id
# - Wrong attribute types (Integer vs String, Hash vs Array)

require 'pangea-aws'

RSpec.describe 'aws_nixos backend type validation' do
  include SynthesisTestHelpers

  # Use a REAL synthesizer context with actual pangea-aws resource methods.
  # This exercises the full type validation pipeline.
  let(:typed_ctx) do
    ctx = create_mock_context
    ctx.extend(Pangea::Resources::AWS)
    ctx
  end

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
  end

  describe '.create_iam' do
    let(:network) do
      Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
    end

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
  end

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

    it 'passes type validation for launch template and ASG' do
      expect {
        Pangea::Kubernetes::Backends::AwsNixos.create_cluster(
          typed_ctx, :typecheck, cluster_config, base_tags, network
        )
      }.not_to raise_error
    end
  end

  describe '.create_node_pool' do
    let(:network) do
      Pangea::Kubernetes::Backends::AwsNixos.create_network(
        typed_ctx, :typecheck, cluster_config, base_tags
      )
    end

    it 'passes type validation for worker launch template and ASG' do
      pool_config = cluster_config.node_pools.find { |p| p.name == :workers }
      expect {
        Pangea::Kubernetes::Backends::AwsNixos.create_node_pool(
          typed_ctx, :typecheck, pool_config, cluster_config, base_tags, network
        )
      }.not_to raise_error
    end
  end

  describe 'full pipeline' do
    it 'passes type validation for the complete kubernetes_cluster call' do
      synth = create_mock_context
      synth.extend(Pangea::Resources::AWS)
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
          vpn: {
            interface: 'wg-test',
            address: '10.100.3.2/24',
            port: 51822,
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
  end
end
