# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::LoadBalancerConfig do
  let(:minimal_attrs) do
    {
      instance_type: 'cx41',
      region: 'nbg1',
      backends: [{ address: '10.0.0.1', port: 6443 }]
    }
  end

  describe 'construction with defaults' do
    let(:config) { described_class.new(minimal_attrs) }

    it 'defaults mode to haproxy' do
      expect(config.mode).to eq('haproxy')
    end

    it 'defaults instance_count to 2' do
      expect(config.instance_count).to eq(2)
    end

    it 'defaults health_check_interval to 5s' do
      expect(config.health_check_interval).to eq('5s')
    end

    it 'defaults max_connections to 50000' do
      expect(config.max_connections).to eq(50_000)
    end

    it 'defaults frontend_ports to [80, 443]' do
      expect(config.frontend_ports).to eq([80, 443])
    end

    it 'defaults tags to empty hash' do
      expect(config.tags).to eq({})
    end

    it 'defaults bgp_asn to nil' do
      expect(config.bgp_asn).to be_nil
    end

    it 'defaults virtual_ips to empty array' do
      expect(config.virtual_ips).to eq([])
    end
  end

  describe '#bare_metal?' do
    it 'returns false for haproxy mode' do
      config = described_class.new(minimal_attrs)
      expect(config.bare_metal?).to be false
    end

    it 'returns true for haproxy-bird mode' do
      config = described_class.new(minimal_attrs.merge(mode: 'haproxy-bird'))
      expect(config.bare_metal?).to be true
    end
  end

  describe 'mode validation' do
    it 'accepts haproxy' do
      expect { described_class.new(minimal_attrs.merge(mode: 'haproxy')) }.not_to raise_error
    end

    it 'accepts haproxy-bird' do
      expect { described_class.new(minimal_attrs.merge(mode: 'haproxy-bird')) }.not_to raise_error
    end

    it 'rejects invalid mode' do
      expect {
        described_class.new(minimal_attrs.merge(mode: 'nginx'))
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'instance_count validation' do
    it 'rejects zero instances' do
      expect {
        described_class.new(minimal_attrs.merge(instance_count: 0))
      }.to raise_error(Dry::Struct::Error)
    end

    it 'accepts one instance' do
      config = described_class.new(minimal_attrs.merge(instance_count: 1))
      expect(config.instance_count).to eq(1)
    end
  end

  describe 'backends validation' do
    it 'rejects empty backends array' do
      expect {
        described_class.new(minimal_attrs.merge(backends: []))
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe '#to_h' do
    it 'includes required fields' do
      config = described_class.new(minimal_attrs)
      hash = config.to_h
      expect(hash[:mode]).to eq('haproxy')
      expect(hash[:instance_type]).to eq('cx41')
      expect(hash[:region]).to eq('nbg1')
      expect(hash[:backends]).to eq([{ address: '10.0.0.1', port: 6443 }])
    end

    it 'omits tags when empty' do
      config = described_class.new(minimal_attrs)
      expect(config.to_h).not_to have_key(:tags)
    end

    it 'includes tags when non-empty' do
      config = described_class.new(minimal_attrs.merge(tags: { Env: 'prod' }))
      expect(config.to_h[:tags]).to eq({ Env: 'prod' })
    end

    it 'omits bgp_asn when nil' do
      config = described_class.new(minimal_attrs)
      expect(config.to_h).not_to have_key(:bgp_asn)
    end

    it 'includes bgp_asn when set' do
      config = described_class.new(minimal_attrs.merge(mode: 'haproxy-bird', bgp_asn: 64512))
      expect(config.to_h[:bgp_asn]).to eq(64512)
    end

    it 'omits virtual_ips when empty' do
      config = described_class.new(minimal_attrs)
      expect(config.to_h).not_to have_key(:virtual_ips)
    end

    it 'includes virtual_ips when non-empty' do
      config = described_class.new(
        minimal_attrs.merge(mode: 'haproxy-bird', virtual_ips: ['192.168.1.100'])
      )
      expect(config.to_h[:virtual_ips]).to eq(['192.168.1.100'])
    end
  end
end
