# frozen_string_literal: true

require 'pangea/kubernetes/types/vpn_config'

RSpec.describe Pangea::Kubernetes::Types::VpnConfig do
  let(:valid_peer) do
    {
      public_key: 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=',
      allowed_ips: ['10.0.0.0/24'],
      preshared_key_file: '/run/secrets/psk'
    }
  end

  let(:valid_link) do
    {
      name: 'wg0',
      private_key_file: '/run/secrets/key',
      address: '10.100.0.1/24',
      listen_port: 51820,
      profile: 'k8s-control-plane',
      peers: [valid_peer],
      firewall: { trust_interface: false, allowed_tcp_ports: [6443] }
    }
  end

  describe '#require_liveness' do
    it 'defaults to false' do
      config = described_class.new(links: [valid_link])
      expect(config.require_liveness).to be false
    end

    it 'can be set to true' do
      config = described_class.new(links: [valid_link], require_liveness: true)
      expect(config.require_liveness).to be true
    end
  end

  describe '#to_h' do
    it 'omits require_liveness when false' do
      config = described_class.new(links: [valid_link])
      expect(config.to_h).not_to have_key(:require_liveness)
    end

    it 'includes require_liveness when true' do
      config = described_class.new(links: [valid_link], require_liveness: true)
      expect(config.to_h[:require_liveness]).to be true
    end
  end

  describe '#validate!' do
    it 'passes for valid config' do
      config = described_class.new(links: [valid_link])
      expect { config.validate! }.not_to raise_error
    end

    it 'passes for empty links' do
      config = described_class.new(links: [])
      expect { config.validate! }.not_to raise_error
    end

    it 'rejects invalid CIDR in address' do
      link = valid_link.merge(address: 'not-valid')
      config = described_class.new(links: [link])
      expect { config.validate! }.to raise_error(ArgumentError, /not a valid CIDR/)
    end

    it 'rejects invalid CIDR in allowed_ips' do
      peer = valid_peer.merge(allowed_ips: ['999.999.999.999/32'])
      link = valid_link.merge(peers: [peer])
      config = described_class.new(links: [link])
      expect { config.validate! }.to raise_error(ArgumentError, /not a valid CIDR/)
    end

    it 'rejects unknown profile' do
      link = valid_link.merge(profile: 'bad-profile')
      config = described_class.new(links: [link])
      expect { config.validate! }.to raise_error(ArgumentError, /not valid/)
    end

    it 'rejects invalid WireGuard key format' do
      peer = valid_peer.merge(public_key: 'not-a-valid-key')
      link = valid_link.merge(peers: [peer])
      config = described_class.new(links: [link])
      expect { config.validate! }.to raise_error(ArgumentError, /WireGuard key/)
    end

    it 'rejects invalid endpoint' do
      peer = valid_peer.merge(endpoint: 'no-port')
      link = valid_link.merge(peers: [peer])
      config = described_class.new(links: [link])
      expect { config.validate! }.to raise_error(ArgumentError, /endpoint/)
    end

    it 'rejects privileged listen port' do
      link = valid_link.merge(listen_port: 80)
      config = described_class.new(links: [link])
      expect { config.validate! }.to raise_error(ArgumentError, /listen_port/)
    end

    it 'rejects out-of-range MTU' do
      link = valid_link.merge(mtu: 100)
      config = described_class.new(links: [link])
      expect { config.validate! }.to raise_error(ArgumentError, /mtu/)
    end

    it 'reports all violations at once' do
      link = {
        name: 'wg0',
        address: 'invalid',
        profile: 'bad',
        listen_port: 80,
        peers: [{ public_key: 'bad', allowed_ips: ['not-cidr'] }]
      }
      config = described_class.new(links: [link])
      expect { config.validate! }.to raise_error(ArgumentError, /3 violation/)
    end
  end
end
