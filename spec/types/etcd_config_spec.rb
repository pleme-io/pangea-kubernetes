# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::EtcdConfig do
  describe 'defaults' do
    subject { described_class.new({}) }

    it 'defaults initial_cluster_state to new' do
      expect(subject.initial_cluster_state).to eq('new')
    end

    it 'defaults data_dir to /var/lib/etcd' do
      expect(subject.data_dir).to eq('/var/lib/etcd')
    end

    it 'defaults external_endpoints to empty' do
      expect(subject.external_endpoints).to eq([])
    end
  end

  describe 'validation' do
    it 'accepts new state' do
      config = described_class.new(initial_cluster_state: 'new')
      expect(config.initial_cluster_state).to eq('new')
    end

    it 'accepts existing state' do
      config = described_class.new(initial_cluster_state: 'existing')
      expect(config.initial_cluster_state).to eq('existing')
    end

    it 'rejects invalid state' do
      expect { described_class.new(initial_cluster_state: 'unknown') }.to raise_error(Dry::Struct::Error)
    end
  end

  describe '#external?' do
    it 'returns false when no endpoints' do
      expect(described_class.new({}).external?).to be false
    end

    it 'returns true when endpoints present' do
      config = described_class.new(external_endpoints: ['https://etcd1:2379'])
      expect(config.external?).to be true
    end
  end

  describe '#to_h' do
    it 'always includes initial_cluster_state and data_dir' do
      hash = described_class.new({}).to_h
      expect(hash[:initial_cluster_state]).to eq('new')
      expect(hash[:data_dir]).to eq('/var/lib/etcd')
    end

    it 'omits nil optional fields' do
      hash = described_class.new({}).to_h
      expect(hash).not_to have_key(:snapshot_count)
      expect(hash).not_to have_key(:ca_file)
    end

    it 'includes external etcd cert paths' do
      config = described_class.new(
        ca_file: '/etc/etcd/ca.pem',
        cert_file: '/etc/etcd/client.pem',
        key_file: '/etc/etcd/client-key.pem',
        external_endpoints: ['https://etcd1:2379', 'https://etcd2:2379']
      )
      hash = config.to_h
      expect(hash[:ca_file]).to eq('/etc/etcd/ca.pem')
      expect(hash[:external_endpoints]).to eq(['https://etcd1:2379', 'https://etcd2:2379'])
    end
  end
end
