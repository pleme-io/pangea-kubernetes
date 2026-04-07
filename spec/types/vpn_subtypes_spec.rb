# frozen_string_literal: true

require 'pangea/kubernetes/types/vpn_config'

RSpec.describe 'VPN config sub-types' do
  describe Pangea::Kubernetes::Types::VpnPeerConfig do
    let(:minimal_attrs) { { public_key: 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=' } }

    it 'constructs with required public_key' do
      peer = described_class.new(minimal_attrs)
      expect(peer.public_key).to eq('YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=')
    end

    it 'defaults endpoint to nil' do
      peer = described_class.new(minimal_attrs)
      expect(peer.endpoint).to be_nil
    end

    it 'defaults allowed_ips to empty array' do
      peer = described_class.new(minimal_attrs)
      expect(peer.allowed_ips).to eq([])
    end

    it 'defaults persistent_keepalive to nil' do
      peer = described_class.new(minimal_attrs)
      expect(peer.persistent_keepalive).to be_nil
    end

    it 'defaults preshared_key_file to nil' do
      peer = described_class.new(minimal_attrs)
      expect(peer.preshared_key_file).to be_nil
    end

    describe '#to_h' do
      it 'includes required fields' do
        peer = described_class.new(minimal_attrs.merge(allowed_ips: ['10.0.0.0/24']))
        hash = peer.to_h
        expect(hash[:public_key]).to eq('YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=')
        expect(hash[:allowed_ips]).to eq(['10.0.0.0/24'])
      end

      it 'omits endpoint when nil' do
        peer = described_class.new(minimal_attrs)
        expect(peer.to_h).not_to have_key(:endpoint)
      end

      it 'includes endpoint when set' do
        peer = described_class.new(minimal_attrs.merge(endpoint: '1.2.3.4:51820'))
        expect(peer.to_h[:endpoint]).to eq('1.2.3.4:51820')
      end

      it 'omits persistent_keepalive when nil' do
        peer = described_class.new(minimal_attrs)
        expect(peer.to_h).not_to have_key(:persistent_keepalive)
      end

      it 'includes persistent_keepalive when set' do
        peer = described_class.new(minimal_attrs.merge(persistent_keepalive: 25))
        expect(peer.to_h[:persistent_keepalive]).to eq(25)
      end

      it 'omits preshared_key_file when nil' do
        peer = described_class.new(minimal_attrs)
        expect(peer.to_h).not_to have_key(:preshared_key_file)
      end

      it 'includes preshared_key_file when set' do
        peer = described_class.new(minimal_attrs.merge(preshared_key_file: '/run/secrets/psk'))
        expect(peer.to_h[:preshared_key_file]).to eq('/run/secrets/psk')
      end
    end
  end

  describe Pangea::Kubernetes::Types::VpnFirewallConfig do
    it 'defaults trust_interface to false' do
      fw = described_class.new({})
      expect(fw.trust_interface).to be false
    end

    it 'defaults allowed_tcp_ports to empty' do
      fw = described_class.new({})
      expect(fw.allowed_tcp_ports).to eq([])
    end

    it 'defaults allowed_udp_ports to empty' do
      fw = described_class.new({})
      expect(fw.allowed_udp_ports).to eq([])
    end

    it 'defaults incoming_udp_port to nil' do
      fw = described_class.new({})
      expect(fw.incoming_udp_port).to be_nil
    end

    describe '#to_h' do
      it 'always includes trust_interface' do
        fw = described_class.new({})
        expect(fw.to_h[:trust_interface]).to be false
      end

      it 'omits allowed_tcp_ports when empty' do
        fw = described_class.new({})
        expect(fw.to_h).not_to have_key(:allowed_tcp_ports)
      end

      it 'includes allowed_tcp_ports when set' do
        fw = described_class.new(allowed_tcp_ports: [6443, 443])
        expect(fw.to_h[:allowed_tcp_ports]).to eq([6443, 443])
      end

      it 'omits allowed_udp_ports when empty' do
        fw = described_class.new({})
        expect(fw.to_h).not_to have_key(:allowed_udp_ports)
      end

      it 'includes allowed_udp_ports when set' do
        fw = described_class.new(allowed_udp_ports: [51820])
        expect(fw.to_h[:allowed_udp_ports]).to eq([51820])
      end

      it 'omits incoming_udp_port when nil' do
        fw = described_class.new({})
        expect(fw.to_h).not_to have_key(:incoming_udp_port)
      end

      it 'includes incoming_udp_port when set' do
        fw = described_class.new(incoming_udp_port: 51820)
        expect(fw.to_h[:incoming_udp_port]).to eq(51820)
      end
    end
  end

  describe Pangea::Kubernetes::Types::VpnLinkConfig do
    let(:minimal_attrs) { { name: 'wg0' } }

    it 'constructs with required name' do
      link = described_class.new(minimal_attrs)
      expect(link.name).to eq('wg0')
    end

    it 'defaults optional fields to nil' do
      link = described_class.new(minimal_attrs)
      expect(link.private_key_file).to be_nil
      expect(link.listen_port).to be_nil
      expect(link.address).to be_nil
      expect(link.profile).to be_nil
      expect(link.mtu).to be_nil
    end

    it 'defaults peers to empty array' do
      link = described_class.new(minimal_attrs)
      expect(link.peers).to eq([])
    end

    it 'defaults firewall to nil' do
      link = described_class.new(minimal_attrs)
      expect(link.firewall).to be_nil
    end

    describe '#to_h' do
      it 'always includes name' do
        link = described_class.new(minimal_attrs)
        expect(link.to_h[:name]).to eq('wg0')
      end

      it 'omits nil fields' do
        link = described_class.new(minimal_attrs)
        hash = link.to_h
        expect(hash).not_to have_key(:private_key_file)
        expect(hash).not_to have_key(:listen_port)
        expect(hash).not_to have_key(:address)
        expect(hash).not_to have_key(:profile)
        expect(hash).not_to have_key(:mtu)
        expect(hash).not_to have_key(:peers)
        expect(hash).not_to have_key(:firewall)
      end

      it 'includes set fields' do
        link = described_class.new(
          name: 'wg0',
          private_key_file: '/run/secrets/key',
          listen_port: 51820,
          address: '10.100.0.1/24',
          profile: 'k8s-control-plane',
          mtu: 1420
        )
        hash = link.to_h
        expect(hash[:private_key_file]).to eq('/run/secrets/key')
        expect(hash[:listen_port]).to eq(51820)
        expect(hash[:address]).to eq('10.100.0.1/24')
        expect(hash[:profile]).to eq('k8s-control-plane')
        expect(hash[:mtu]).to eq(1420)
      end

      it 'serializes peers' do
        link = described_class.new(
          name: 'wg0',
          peers: [{ public_key: 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=', allowed_ips: ['10.0.0.0/24'] }]
        )
        hash = link.to_h
        expect(hash[:peers]).to be_an(Array)
        expect(hash[:peers].first[:public_key]).to eq('YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=')
      end

      it 'serializes firewall' do
        link = described_class.new(
          name: 'wg0',
          firewall: { trust_interface: true, allowed_tcp_ports: [6443] }
        )
        hash = link.to_h
        expect(hash[:firewall][:trust_interface]).to be true
        expect(hash[:firewall][:allowed_tcp_ports]).to eq([6443])
      end
    end
  end

  describe Pangea::Kubernetes::Types::VpnConfig do
    describe '#to_h' do
      it 'returns empty hash when no links' do
        config = described_class.new(links: [])
        expect(config.to_h).to eq({})
      end
    end

    describe '#validate!' do
      it 'accepts valid IPv6 CIDR address' do
        config = described_class.new(
          links: [{
            name: 'wg0',
            address: 'fd00::1/128',
            peers: [{
              public_key: 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=',
              allowed_ips: ['fd00::/64']
            }]
          }]
        )
        expect { config.validate! }.not_to raise_error
      end

      it 'accepts valid IPv6 endpoint' do
        config = described_class.new(
          links: [{
            name: 'wg0',
            address: '10.100.0.1/24',
            peers: [{
              public_key: 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=',
              allowed_ips: ['10.0.0.0/24'],
              endpoint: '[::1]:51820'
            }]
          }]
        )
        expect { config.validate! }.not_to raise_error
      end

      it 'rejects IPv6 endpoint without port' do
        config = described_class.new(
          links: [{
            name: 'wg0',
            address: '10.100.0.1/24',
            peers: [{
              public_key: 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=',
              allowed_ips: ['10.0.0.0/24'],
              endpoint: '[::1]'
            }]
          }]
        )
        expect { config.validate! }.to raise_error(ArgumentError, /endpoint/)
      end

      it 'accepts listen_port of 0 (kernel-assigned)' do
        config = described_class.new(
          links: [{
            name: 'wg0',
            listen_port: 0,
            address: '10.100.0.1/24',
            peers: []
          }]
        )
        expect { config.validate! }.not_to raise_error
      end

      it 'rejects listen_port between 1 and 1023' do
        config = described_class.new(
          links: [{
            name: 'wg0',
            listen_port: 443,
            address: '10.100.0.1/24',
            peers: []
          }]
        )
        expect { config.validate! }.to raise_error(ArgumentError, /listen_port/)
      end

      it 'accepts max valid MTU (9000)' do
        config = described_class.new(
          links: [{
            name: 'wg0',
            mtu: 9000,
            address: '10.100.0.1/24',
            peers: []
          }]
        )
        expect { config.validate! }.not_to raise_error
      end

      it 'accepts min valid MTU (1280)' do
        config = described_class.new(
          links: [{
            name: 'wg0',
            mtu: 1280,
            address: '10.100.0.1/24',
            peers: []
          }]
        )
        expect { config.validate! }.not_to raise_error
      end

      it 'rejects MTU above 9000' do
        config = described_class.new(
          links: [{
            name: 'wg0',
            mtu: 9001,
            address: '10.100.0.1/24',
            peers: []
          }]
        )
        expect { config.validate! }.to raise_error(ArgumentError, /mtu/)
      end

      it 'rejects CIDR without prefix' do
        config = described_class.new(
          links: [{
            name: 'wg0',
            address: '10.100.0.1',
            peers: []
          }]
        )
        expect { config.validate! }.to raise_error(ArgumentError, /CIDR/)
      end

      it 'rejects CIDR with non-numeric prefix' do
        config = described_class.new(
          links: [{
            name: 'wg0',
            address: '10.100.0.1/abc',
            peers: []
          }]
        )
        expect { config.validate! }.to raise_error(ArgumentError, /CIDR/)
      end

      it 'rejects IPv4 CIDR with prefix > 32' do
        config = described_class.new(
          links: [{
            name: 'wg0',
            address: '10.100.0.1/33',
            peers: []
          }]
        )
        expect { config.validate! }.to raise_error(ArgumentError, /CIDR/)
      end
    end
  end
end
