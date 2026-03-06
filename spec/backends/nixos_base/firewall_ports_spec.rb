# frozen_string_literal: true

RSpec.describe 'NixosBase firewall ports' do
  # Test via each backend that extends NixosBase
  %i[AwsNixos GcpNixos AzureNixos HcloudK3s].each do |backend_name|
    backend = Pangea::Kubernetes::Backends.const_get(backend_name)

    describe "#{backend_name}" do
      it 'returns consistent k3s ports across backends' do
        ports = backend.base_firewall_ports(:k3s)
        expect(ports.keys).to include(:ssh, :http, :https, :api, :kubelet, :etcd, :vxlan)
        expect(ports.keys).not_to include(:controller_manager, :scheduler)
      end

      it 'returns consistent kubernetes ports across backends' do
        ports = backend.base_firewall_ports(:kubernetes)
        expect(ports.keys).to include(:ssh, :http, :https, :api, :kubelet, :etcd, :vxlan,
                                      :controller_manager, :scheduler)
      end

      it 'uses identical port numbers for k3s' do
        ports = backend.base_firewall_ports(:k3s)
        expect(ports[:ssh][:port]).to eq(22)
        expect(ports[:api][:port]).to eq(6443)
        expect(ports[:etcd][:port]).to eq('2379-2380')
        expect(ports[:vxlan][:port]).to eq(8472)
      end

      it 'uses identical port numbers for kubernetes-specific ports' do
        ports = backend.base_firewall_ports(:kubernetes)
        expect(ports[:controller_manager][:port]).to eq(10_257)
        expect(ports[:scheduler][:port]).to eq(10_259)
      end
    end
  end
end
