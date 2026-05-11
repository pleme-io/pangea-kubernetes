# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::PersistentStateConfig do
  describe 'defaults' do
    subject { described_class.new({}) }

    it 'defaults size_gb to 50' do
      expect(subject.size_gb).to eq(50)
    end

    it 'defaults volume_type to gp3' do
      expect(subject.volume_type).to eq('gp3')
    end

    it 'defaults mount_path to k3s data dir' do
      expect(subject.mount_path).to eq('/var/lib/rancher/k3s')
    end

    it 'defaults filesystem to ext4' do
      expect(subject.filesystem).to eq('ext4')
    end

    it 'defaults discovery_tag to PersistentStateFor' do
      expect(subject.discovery_tag).to eq('PersistentStateFor')
    end

    it 'defaults encrypted to true' do
      expect(subject.encrypted).to be true
    end

    it 'leaves kms_key_id / iops / throughput / availability_zone unset' do
      expect(subject.kms_key_id).to be_nil
      expect(subject.iops).to be_nil
      expect(subject.throughput).to be_nil
      expect(subject.availability_zone).to be_nil
    end
  end

  describe 'validation' do
    it 'rejects size_gb below 8' do
      expect { described_class.new(size_gb: 4) }.to raise_error(Dry::Struct::Error)
    end

    it 'accepts size_gb at the 8 GiB minimum' do
      expect(described_class.new(size_gb: 8).size_gb).to eq(8)
    end

    it 'coerces stringy size_gb' do
      expect(described_class.new(size_gb: '200').size_gb).to eq(200)
    end

    it 'rejects unknown volume_type' do
      expect { described_class.new(volume_type: 'magnetic') }.to raise_error(Dry::Struct::Error)
    end

    %w[gp3 gp2 io1 io2 st1 sc1].each do |vt|
      it "accepts #{vt} volume_type" do
        expect(described_class.new(volume_type: vt).volume_type).to eq(vt)
      end
    end

    it 'rejects unknown filesystem' do
      expect { described_class.new(filesystem: 'btrfs') }.to raise_error(Dry::Struct::Error)
    end

    %w[ext4 xfs].each do |fs|
      it "accepts #{fs} filesystem" do
        expect(described_class.new(filesystem: fs).filesystem).to eq(fs)
      end
    end

    it 'coerces iops from string' do
      expect(described_class.new(iops: '5000').iops).to eq(5000)
    end

    it 'coerces throughput from string' do
      expect(described_class.new(throughput: '250').throughput).to eq(250)
    end
  end

  describe '#to_h' do
    it 'always includes the required defaults' do
      hash = described_class.new({}).to_h
      expect(hash).to include(
        size_gb: 50,
        volume_type: 'gp3',
        mount_path: '/var/lib/rancher/k3s',
        filesystem: 'ext4',
        discovery_tag: 'PersistentStateFor',
        encrypted: true
      )
    end

    it 'omits optional fields when unset' do
      hash = described_class.new({}).to_h
      expect(hash).not_to have_key(:kms_key_id)
      expect(hash).not_to have_key(:iops)
      expect(hash).not_to have_key(:throughput)
      expect(hash).not_to have_key(:availability_zone)
    end

    it 'includes optional fields when set' do
      hash = described_class.new(
        kms_key_id: 'arn:aws:kms:us-east-1:111:key/abc',
        iops: 6000,
        throughput: 300,
        availability_zone: 'us-east-1a'
      ).to_h
      expect(hash[:kms_key_id]).to eq('arn:aws:kms:us-east-1:111:key/abc')
      expect(hash[:iops]).to eq(6000)
      expect(hash[:throughput]).to eq(300)
      expect(hash[:availability_zone]).to eq('us-east-1a')
    end

    it 'round-trips through ClusterConfig.persistent_state' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        region: 'us-east-1',
        node_pools: [{
          name: :system,
          instance_types: ['t3.medium']
        }],
        persistent_state: {
          size_gb: 100,
          volume_type: 'gp3',
          mount_path: '/data',
          availability_zone: 'us-east-1a'
        }
      )
      expect(config.persistent_state).to be_a(described_class)
      expect(config.persistent_state.size_gb).to eq(100)
      expect(config.persistent_state.mount_path).to eq('/data')
      expect(config.to_h[:persistent_state]).to include(size_gb: 100, mount_path: '/data')
    end

    it 'is omitted from ClusterConfig.to_h when not configured' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        region: 'us-east-1',
        node_pools: [{ name: :system, instance_types: ['t3.medium'] }]
      )
      expect(config.persistent_state).to be_nil
      expect(config.to_h).not_to have_key(:persistent_state)
    end
  end
end
