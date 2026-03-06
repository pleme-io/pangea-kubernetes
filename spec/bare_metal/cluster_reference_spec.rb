# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::BareMetal::ClusterReference do
  # Use simple Struct objects instead of MockResourceRef because MockResourceRef
  # defines ipv4_address as a method that returns terraform expressions.
  ServerStub = Struct.new(:ipv4_address, keyword_init: true)

  let(:cp_server_1) { ServerStub.new(ipv4_address: '10.0.0.1') }
  let(:cp_server_2) { ServerStub.new(ipv4_address: '10.0.0.2') }
  let(:worker_1) { ServerStub.new(ipv4_address: '10.0.1.1') }
  let(:worker_2) { ServerStub.new(ipv4_address: '10.0.1.2') }

  let(:cluster) do
    described_class.new(
      name: :production,
      control_plane_servers: [cp_server_1, cp_server_2],
      worker_servers: [worker_1, worker_2],
      config: { distribution: 'k3s', profile: 'cilium-standard' }
    )
  end

  describe '#initialize' do
    it 'sets name' do
      expect(cluster.name).to eq(:production)
    end

    it 'sets control_plane_servers' do
      expect(cluster.control_plane_servers.size).to eq(2)
    end

    it 'sets worker_servers' do
      expect(cluster.worker_servers.size).to eq(2)
    end

    it 'sets config' do
      expect(cluster.config[:distribution]).to eq('k3s')
    end

    it 'defaults worker_servers to empty array' do
      ref = described_class.new(
        name: :test,
        control_plane_servers: [cp_server_1]
      )
      expect(ref.worker_servers).to eq([])
    end

    it 'defaults config to empty hash' do
      ref = described_class.new(
        name: :test,
        control_plane_servers: [cp_server_1]
      )
      expect(ref.config).to eq({})
    end
  end

  describe '#endpoint' do
    it 'returns the primary server IP address' do
      expect(cluster.endpoint).to eq('10.0.0.1')
    end

    it 'returns nil when no control plane servers' do
      ref = described_class.new(
        name: :empty,
        control_plane_servers: []
      )
      expect(ref.endpoint).to be_nil
    end
  end

  describe '#api_port' do
    it 'returns 6443' do
      expect(cluster.api_port).to eq(6443)
    end
  end

  describe '#api_endpoint' do
    it 'returns the full API endpoint URL' do
      expect(cluster.api_endpoint).to eq('https://10.0.0.1:6443')
    end
  end

  describe '#all_node_ips' do
    it 'returns IPs from both control plane and worker servers' do
      ips = cluster.all_node_ips
      expect(ips.size).to eq(4)
      expect(ips).to include('10.0.0.1')
      expect(ips).to include('10.0.0.2')
      expect(ips).to include('10.0.1.1')
      expect(ips).to include('10.0.1.2')
    end

    it 'returns only control plane IPs when no workers' do
      ref = described_class.new(
        name: :test,
        control_plane_servers: [cp_server_1]
      )
      expect(ref.all_node_ips).to eq(['10.0.0.1'])
    end
  end

  describe '#to_h' do
    it 'serializes to hash' do
      hash = cluster.to_h
      expect(hash[:name]).to eq(:production)
      expect(hash[:endpoint]).to eq('10.0.0.1')
      expect(hash[:api_port]).to eq(6443)
      expect(hash[:control_plane_count]).to eq(2)
      expect(hash[:worker_count]).to eq(2)
    end

    it 'handles empty cluster' do
      ref = described_class.new(
        name: :empty,
        control_plane_servers: []
      )
      hash = ref.to_h
      expect(hash[:control_plane_count]).to eq(0)
      expect(hash[:worker_count]).to eq(0)
      expect(hash[:endpoint]).to be_nil
    end
  end
end
