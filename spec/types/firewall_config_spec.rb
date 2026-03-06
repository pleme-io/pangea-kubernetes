# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::FirewallConfig do
  describe 'defaults' do
    subject { described_class.new({}) }

    it 'defaults enabled to true' do
      expect(subject.enabled).to be true
    end

    it 'defaults extra_tcp_ports to empty' do
      expect(subject.extra_tcp_ports).to eq([])
    end

    it 'defaults extra_udp_ports to empty' do
      expect(subject.extra_udp_ports).to eq([])
    end

    it 'defaults trusted_cidrs to empty' do
      expect(subject.trusted_cidrs).to eq([])
    end

    it 'defaults allow_intra_cluster to true' do
      expect(subject.allow_intra_cluster).to be true
    end
  end

  describe 'custom values' do
    subject do
      described_class.new(
        enabled: false,
        extra_tcp_ports: [8080, 9090],
        extra_udp_ports: [5353],
        trusted_cidrs: ['10.0.0.0/8', '172.16.0.0/12'],
        allow_intra_cluster: false
      )
    end

    it 'accepts custom extra_tcp_ports' do
      expect(subject.extra_tcp_ports).to eq([8080, 9090])
    end

    it 'accepts custom trusted_cidrs' do
      expect(subject.trusted_cidrs).to eq(['10.0.0.0/8', '172.16.0.0/12'])
    end
  end

  describe '#to_h' do
    it 'omits empty arrays' do
      config = described_class.new({})
      hash = config.to_h
      expect(hash).not_to have_key(:extra_tcp_ports)
      expect(hash).not_to have_key(:extra_udp_ports)
      expect(hash).not_to have_key(:trusted_cidrs)
    end

    it 'includes non-empty arrays' do
      config = described_class.new(extra_tcp_ports: [8080])
      hash = config.to_h
      expect(hash[:extra_tcp_ports]).to eq([8080])
    end

    it 'always includes enabled and allow_intra_cluster' do
      hash = described_class.new({}).to_h
      expect(hash).to have_key(:enabled)
      expect(hash).to have_key(:allow_intra_cluster)
    end
  end
end
