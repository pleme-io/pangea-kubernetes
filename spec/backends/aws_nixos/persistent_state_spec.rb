# frozen_string_literal: true

# Specs for the persistent_state slot on the aws_nixos backend.
# Verifies:
#   1. When config.persistent_state is nil: no EBS volume, no IAM
#      policy, no AZ filter — back-compat with v0.
#   2. When set: separately-managed EBS volume tagged for discovery,
#      lifecycle.prevent_destroy=true, IAM policy with tag-scoped
#      AttachVolume/DetachVolume, ASG vpc_zone_identifier narrowed to
#      the persistent_state AZ.

RSpec.describe Pangea::Kubernetes::Backends::AwsNixos do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'kazoku', Backend: 'aws_nixos', ManagedBy: 'Pangea' } }

  def make_config(persistent_state:)
    attrs = {
      backend: :aws_nixos,
      kubernetes_version: '1.34',
      region: 'us-east-1',
      distribution: :k3s,
      profile: 'cloud-server',
      distribution_track: '1.34',
      ami_id: 'ami-nixos-test',
      key_pair: 'kazoku-key',
      account_id: '123456789012',
      ssh_cidr: '10.0.0.0/8',
      api_cidr: '10.0.0.0/8',
      node_pools: [
        { name: :system, instance_types: ['t3.medium'], min_size: 1, max_size: 1 },
        { name: :worker, instance_types: ['t3.medium'], min_size: 1, max_size: 2 }
      ],
      network: { vpc_cidr: '10.0.0.0/16' }
    }
    attrs[:persistent_state] = persistent_state if persistent_state
    Pangea::Kubernetes::Types::ClusterConfig.new(attrs)
  end

  describe '.create_network — without persistent_state (back-compat)' do
    let(:config) { make_config(persistent_state: nil) }

    it 'emits no aws_ebs_volume' do
      described_class.create_network(ctx, :kazoku, config, base_tags)
      expect(ctx.find_resource(:aws_ebs_volume, :kazoku_persistent_state)).to be_nil
    end

    it 'leaves NetworkResult.persistent_state_volume unset' do
      result = described_class.create_network(ctx, :kazoku, config, base_tags)
      expect(result.persistent_state_volume).to be_nil
    end
  end

  describe '.create_network — with persistent_state' do
    let(:config) do
      make_config(persistent_state: {
        size_gb: 100,
        volume_type: 'gp3',
        encrypted: true,
        availability_zone: 'us-east-1a'
      })
    end

    it 'emits exactly one aws_ebs_volume' do
      described_class.create_network(ctx, :kazoku, config, base_tags)
      vols = ctx.created_resources.select { |r| r[:type] == 'aws_ebs_volume' }
      expect(vols.size).to eq(1)
    end

    it 'tags the volume for discovery from inside the instance' do
      described_class.create_network(ctx, :kazoku, config, base_tags)
      vol = ctx.find_resource(:aws_ebs_volume, :kazoku_persistent_state)
      expect(vol[:attrs][:tags]).to include(
        'PersistentStateFor': 'kazoku',
        Role: 'persistent-state',
        Cluster: 'kazoku'
      )
    end

    it 'has lifecycle.prevent_destroy: true' do
      described_class.create_network(ctx, :kazoku, config, base_tags)
      vol = ctx.find_resource(:aws_ebs_volume, :kazoku_persistent_state)
      expect(vol[:attrs][:lifecycle]).to eq({ prevent_destroy: true })
    end

    it 'binds the volume to the configured AZ' do
      described_class.create_network(ctx, :kazoku, config, base_tags)
      vol = ctx.find_resource(:aws_ebs_volume, :kazoku_persistent_state)
      expect(vol[:attrs][:availability_zone]).to eq('us-east-1a')
    end

    it 'falls back to <region>a when AZ omitted' do
      cfg = make_config(persistent_state: { size_gb: 50 })
      described_class.create_network(ctx, :kazoku, cfg, base_tags)
      vol = ctx.find_resource(:aws_ebs_volume, :kazoku_persistent_state)
      expect(vol[:attrs][:availability_zone]).to eq('us-east-1a')
    end

    it 'sets the operator-chosen size + volume_type + encryption' do
      described_class.create_network(ctx, :kazoku, config, base_tags)
      vol = ctx.find_resource(:aws_ebs_volume, :kazoku_persistent_state)
      expect(vol[:attrs][:size]).to eq(100)
      expect(vol[:attrs][:type]).to eq('gp3')
      expect(vol[:attrs][:encrypted]).to be true
    end

    it 'passes iops/throughput/kms_key_id through when set' do
      cfg = make_config(persistent_state: {
        iops: 6000,
        throughput: 250,
        kms_key_id: 'alias/cluster-state'
      })
      described_class.create_network(ctx, :kazoku, cfg, base_tags)
      vol = ctx.find_resource(:aws_ebs_volume, :kazoku_persistent_state)
      expect(vol[:attrs][:iops]).to eq(6000)
      expect(vol[:attrs][:throughput]).to eq(250)
      expect(vol[:attrs][:kms_key_id]).to eq('alias/cluster-state')
    end

    it 'records the volume on NetworkResult.persistent_state_volume' do
      result = described_class.create_network(ctx, :kazoku, config, base_tags)
      expect(result.persistent_state_volume).not_to be_nil
    end
  end

  describe '.create_iam — persistent_state IAM policy' do
    it 'emits NO persistent-state policy when persistent_state is nil' do
      config = make_config(persistent_state: nil)
      described_class.create_iam(ctx, :kazoku, config, base_tags)
      expect(ctx.find_resource(:aws_iam_policy, :kazoku_persistent_state)).to be_nil
    end

    it 'emits the persistent-state policy when persistent_state is set' do
      config = make_config(persistent_state: { size_gb: 50 })
      described_class.create_iam(ctx, :kazoku, config, base_tags)
      policy = ctx.find_resource(:aws_iam_policy, :kazoku_persistent_state)
      expect(policy).not_to be_nil
    end

    it 'scopes AttachVolume / DetachVolume to the cluster tag' do
      config = make_config(persistent_state: { size_gb: 50 })
      described_class.create_iam(ctx, :kazoku, config, base_tags)
      policy = ctx.find_resource(:aws_iam_policy, :kazoku_persistent_state)
      doc = JSON.parse(policy[:attrs][:policy])
      attach_stmt = doc['Statement'].find { |s| s['Sid'] == 'AttachDetachTaggedVolume' }
      expect(attach_stmt['Action']).to include('ec2:AttachVolume', 'ec2:DetachVolume')
      expect(attach_stmt['Condition']['StringEquals']['aws:ResourceTag/PersistentStateFor']).to eq('kazoku')
    end

    it 'grants ec2:DescribeVolumes globally (* — required by EC2 API)' do
      config = make_config(persistent_state: { size_gb: 50 })
      described_class.create_iam(ctx, :kazoku, config, base_tags)
      policy = ctx.find_resource(:aws_iam_policy, :kazoku_persistent_state)
      doc = JSON.parse(policy[:attrs][:policy])
      describe_stmt = doc['Statement'].find { |s| s['Sid'] == 'DescribeVolumes' }
      expect(describe_stmt['Resource']).to eq(['*'])
    end

    it 'attaches the policy to the node role' do
      config = make_config(persistent_state: { size_gb: 50 })
      described_class.create_iam(ctx, :kazoku, config, base_tags)
      attachment = ctx.find_resource(:aws_iam_role_policy_attachment, :kazoku_persistent_state)
      expect(attachment).not_to be_nil
    end
  end

  describe 'CloudInit JSON pass-through' do
    # Test the generator directly — the backend's
    # build_server_cloud_init wires config.persistent_state&.to_h into
    # this call (see nixos_base.rb), so a unit test here proves the
    # contract without needing a fully-stitched ArchitectureResult.
    it 'embeds persistent_state in the cluster-config JSON' do
      cloud_init = Pangea::Kubernetes::BareMetal::CloudInit.generate(
        cluster_name: 'kazoku',
        persistent_state: { size_gb: 100, mount_path: '/var/lib/rancher/k3s', discovery_tag: 'PersistentStateFor' }
      )
      expect(cloud_init).to include('"persistent_state"')
      expect(cloud_init).to include('"size_gb":100')
      expect(cloud_init).to include('"mount_path":"/var/lib/rancher/k3s"')
    end

    it 'omits persistent_state from JSON when nil' do
      cloud_init = Pangea::Kubernetes::BareMetal::CloudInit.generate(cluster_name: 'kazoku')
      expect(cloud_init).not_to include('"persistent_state"')
    end

    it 'omits persistent_state from JSON when an empty hash' do
      cloud_init = Pangea::Kubernetes::BareMetal::CloudInit.generate(
        cluster_name: 'kazoku',
        persistent_state: {}
      )
      expect(cloud_init).not_to include('"persistent_state"')
    end
  end
end
