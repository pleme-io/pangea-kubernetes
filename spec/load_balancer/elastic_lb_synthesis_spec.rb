# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::LoadBalancer do
  include SynthesisTestHelpers

  # Create a test class that includes the LoadBalancer module
  # and provides mock provider methods
  let(:lb_context) do
    ctx = create_mock_context
    ctx.extend(Pangea::Kubernetes::LoadBalancer)
    ctx
  end

  let(:minimal_lb_config) do
    {
      instance_type: 'cx21',
      region: 'nbg1',
      backends: [
        { name: 'node-1', address: '10.0.0.1', port: 30080 },
        { name: 'node-2', address: '10.0.0.2', port: 30080 }
      ]
    }
  end

  describe '#elastic_load_balancer' do
    it 'creates HAProxy servers' do
      result = lb_context.elastic_load_balancer(:web, minimal_lb_config)

      expect(result).to have_key(:haproxy_servers)
      expect(result[:haproxy_servers].size).to eq(2) # default instance_count
    end

    it 'creates Hetzner Cloud LB in managed mode' do
      result = lb_context.elastic_load_balancer(:web, minimal_lb_config)

      expect(result).to have_key(:cloud_lb)
      cloud_lb = lb_context.created_resources.find { |r| r[:type] == 'hcloud_load_balancer' }
      expect(cloud_lb).not_to be_nil
    end

    it 'creates LB targets for each HAProxy server' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config)

      targets = lb_context.created_resources.select { |r| r[:type] == 'hcloud_load_balancer_target' }
      expect(targets.size).to eq(2)
    end

    it 'creates services for default ports (80, 443)' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config)

      services = lb_context.created_resources.select { |r| r[:type] == 'hcloud_load_balancer_service' }
      expect(services.size).to eq(2)
    end

    it 'respects custom instance_count' do
      result = lb_context.elastic_load_balancer(:web, minimal_lb_config.merge(instance_count: 4))
      expect(result[:haproxy_servers].size).to eq(4)
    end

    it 'respects custom frontend_ports' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config.merge(frontend_ports: [80, 443, 8080]))

      services = lb_context.created_resources.select { |r| r[:type] == 'hcloud_load_balancer_service' }
      expect(services.size).to eq(3)
    end

    it 'skips Cloud LB in bare-metal mode' do
      result = lb_context.elastic_load_balancer(:web, minimal_lb_config.merge(
        mode: 'haproxy-bird',
        bgp_asn: 65000,
        bgp_neighbor: '10.0.0.254',
        vrrp_interface: 'eth0',
        virtual_ips: ['10.0.0.100']
      ))

      expect(result).not_to have_key(:cloud_lb)
      expect(result).to have_key(:haproxy_servers)
    end

    it 'includes HAProxy config in cloud-init user_data' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config)

      haproxy_server = lb_context.created_resources.find { |r|
        r[:type] == 'hcloud_server' && r[:name] == :web_haproxy_0
      }
      user_data = haproxy_server[:attrs][:user_data]
      expect(user_data).to include('#cloud-config')
      expect(user_data).to include('haproxy-config.json')
      expect(user_data).to include('"role":"haproxy"')
    end

    it 'includes BGP config in bare-metal mode cloud-init' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config.merge(
        mode: 'haproxy-bird',
        bgp_asn: 65000,
        bgp_neighbor: '10.0.0.254'
      ))

      haproxy_server = lb_context.created_resources.find { |r|
        r[:type] == 'hcloud_server' && r[:name] == :web_haproxy_0
      }
      user_data = haproxy_server[:attrs][:user_data]
      expect(user_data).to include('"bgp_asn":65000')
      expect(user_data).to include('"bgp_neighbor":"10.0.0.254"')
    end
  end
end
