# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Backends::NixosBase do
  describe 'COMMON_PORTS' do
    it 'defines 7 base ports' do
      expect(described_class::COMMON_PORTS.size).to eq(7)
    end

    it 'includes ssh, http, https, api, kubelet, etcd, vxlan' do
      expected_keys = %i[ssh http https api kubelet etcd vxlan]
      expect(described_class::COMMON_PORTS.keys).to match_array(expected_keys)
    end

    it 'marks ssh/http/https/api as public' do
      %i[ssh http https api].each do |port|
        expect(described_class::COMMON_PORTS[port][:public]).to be(true), "#{port} should be public"
      end
    end

    it 'marks kubelet/etcd/vxlan as internal' do
      %i[kubelet etcd vxlan].each do |port|
        expect(described_class::COMMON_PORTS[port][:public]).to be(false), "#{port} should be internal"
      end
    end
  end

  describe 'VANILLA_K8S_PORTS' do
    it 'defines controller_manager and scheduler' do
      expect(described_class::VANILLA_K8S_PORTS.keys).to match_array(%i[controller_manager scheduler])
    end

    it 'uses correct port numbers' do
      expect(described_class::VANILLA_K8S_PORTS[:controller_manager][:port]).to eq(10_257)
      expect(described_class::VANILLA_K8S_PORTS[:scheduler][:port]).to eq(10_259)
    end
  end

  # Test via a backend that extends NixosBase
  describe '#base_firewall_ports' do
    let(:backend) { Pangea::Kubernetes::Backends::AwsNixos }

    it 'returns 7 ports for k3s' do
      ports = backend.base_firewall_ports(:k3s)
      expect(ports.size).to eq(7)
    end

    it 'returns 9 ports for vanilla kubernetes' do
      ports = backend.base_firewall_ports(:kubernetes)
      expect(ports.size).to eq(9)
    end

    it 'includes controller_manager and scheduler for kubernetes' do
      ports = backend.base_firewall_ports(:kubernetes)
      expect(ports).to have_key(:controller_manager)
      expect(ports).to have_key(:scheduler)
    end

    it 'does not include k8s-specific ports for k3s' do
      ports = backend.base_firewall_ports(:k3s)
      expect(ports).not_to have_key(:controller_manager)
      expect(ports).not_to have_key(:scheduler)
    end
  end
end
