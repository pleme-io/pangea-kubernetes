# frozen_string_literal: true

RSpec.describe 'LoadBalancer edge cases' do
  include SynthesisTestHelpers

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
        { name: 'node-1', address: '10.0.0.1', port: 30080 }
      ]
    }
  end

  describe 'bare metal mode (haproxy-bird)' do
    let(:bare_metal_config) do
      minimal_lb_config.merge(
        mode: 'haproxy-bird',
        bgp_asn: 65000,
        bgp_neighbor: '10.0.0.254',
        vrrp_interface: 'eth0',
        virtual_ips: ['10.0.0.100', '10.0.0.101']
      )
    end

    it 'creates HAProxy servers but no cloud LB' do
      result = lb_context.elastic_load_balancer(:web, bare_metal_config)
      expect(result).to have_key(:haproxy_servers)
      expect(result).not_to have_key(:cloud_lb)
    end

    it 'includes vrrp_interface in cloud-init config' do
      lb_context.elastic_load_balancer(:web, bare_metal_config)
      haproxy = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_0 }
      expect(haproxy[:attrs][:user_data]).to include('"vrrp_interface":"eth0"')
    end

    it 'includes virtual_ips in cloud-init config' do
      lb_context.elastic_load_balancer(:web, bare_metal_config)
      haproxy = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_0 }
      expect(haproxy[:attrs][:user_data]).to include('"virtual_ips":["10.0.0.100","10.0.0.101"]')
    end

    it 'includes bgp_asn in cloud-init config' do
      lb_context.elastic_load_balancer(:web, bare_metal_config)
      haproxy = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_0 }
      expect(haproxy[:attrs][:user_data]).to include('"bgp_asn":65000')
    end

    it 'includes bgp_neighbor in cloud-init config' do
      lb_context.elastic_load_balancer(:web, bare_metal_config)
      haproxy = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_0 }
      expect(haproxy[:attrs][:user_data]).to include('"bgp_neighbor":"10.0.0.254"')
    end

    it 'creates correct number of HAProxy servers' do
      result = lb_context.elastic_load_balancer(:web, bare_metal_config.merge(instance_count: 3))
      expect(result[:haproxy_servers].size).to eq(3)
    end
  end

  describe 'managed mode (haproxy)' do
    it 'sets health check interval from config' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config.merge(health_check_interval: '10s'))
      services = lb_context.created_resources.select { |r| r[:type] == 'hcloud_load_balancer_service' }
      services.each do |svc|
        expect(svc[:attrs][:health_check][:interval]).to eq(10)
      end
    end

    it 'uses https protocol for port 443' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config)
      svc_443 = lb_context.created_resources.find { |r|
        r[:type] == 'hcloud_load_balancer_service' && r[:attrs][:listen_port] == 443
      }
      expect(svc_443[:attrs][:protocol]).to eq('https')
    end

    it 'uses http protocol for port 80' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config)
      svc_80 = lb_context.created_resources.find { |r|
        r[:type] == 'hcloud_load_balancer_service' && r[:attrs][:listen_port] == 80
      }
      expect(svc_80[:attrs][:protocol]).to eq('http')
    end

    it 'uses http protocol for non-443 custom ports' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config.merge(frontend_ports: [8080]))
      svc = lb_context.created_resources.find { |r| r[:type] == 'hcloud_load_balancer_service' }
      expect(svc[:attrs][:protocol]).to eq('http')
    end

    it 'creates lb targets linked to haproxy servers' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config)
      targets = lb_context.created_resources.select { |r| r[:type] == 'hcloud_load_balancer_target' }
      targets.each do |target|
        expect(target[:attrs][:type]).to eq('server')
      end
    end

    it 'assigns Hetzner-compatible labels (lowercase, underscored)' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config)
      haproxy = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_0 }
      labels = haproxy[:attrs][:labels]
      # All keys should be lowercase and underscore-separated
      labels.each_key do |key|
        expect(key).to match(/\A[a-z0-9_]+\z/)
      end
    end

    it 'includes node_index in server labels' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config)
      haproxy_0 = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_0 }
      haproxy_1 = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_1 }
      expect(haproxy_0[:attrs][:labels]['node_index']).to eq('0')
      expect(haproxy_1[:attrs][:labels]['node_index']).to eq('1')
    end
  end

  describe 'cloud-init content' do
    it 'includes cluster_name in HAProxy config' do
      lb_context.elastic_load_balancer(:api, minimal_lb_config)
      haproxy = lb_context.created_resources.find { |r| r[:name] == :api_haproxy_0 }
      expect(haproxy[:attrs][:user_data]).to include('"cluster_name":"api"')
    end

    it 'includes mode in HAProxy config' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config)
      haproxy = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_0 }
      expect(haproxy[:attrs][:user_data]).to include('"mode":"haproxy"')
    end

    it 'includes max_connections in HAProxy config' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config.merge(max_connections: 100_000))
      haproxy = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_0 }
      expect(haproxy[:attrs][:user_data]).to include('"max_connections":100000')
    end

    it 'includes frontend_ports in HAProxy config' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config)
      haproxy = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_0 }
      expect(haproxy[:attrs][:user_data]).to include('"frontend_ports":[80,443]')
    end

    it 'includes backends in HAProxy config' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config)
      haproxy = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_0 }
      expect(haproxy[:attrs][:user_data]).to include('"backends"')
      expect(haproxy[:attrs][:user_data]).to include('"address":"10.0.0.1"')
    end

    it 'starts pangea-haproxy-bootstrap service' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config)
      haproxy = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_0 }
      expect(haproxy[:attrs][:user_data]).to include('pangea-haproxy-bootstrap')
    end

    it 'includes correct node_index for each server' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config.merge(instance_count: 3))
      (0..2).each do |idx|
        haproxy = lb_context.created_resources.find { |r| r[:name] == :"web_haproxy_#{idx}" }
        expect(haproxy[:attrs][:user_data]).to include("\"node_index\":#{idx}")
      end
    end
  end

  describe 'custom tags' do
    it 'merges user tags into resource labels' do
      lb_context.elastic_load_balancer(:web, minimal_lb_config.merge(
        tags: { Environment: 'production', Team: 'platform' }
      ))
      cloud_lb = lb_context.created_resources.find { |r| r[:type] == 'hcloud_load_balancer' }
      labels = cloud_lb[:attrs][:labels]
      expect(labels).to include('environment' => 'production')
      expect(labels).to include('team' => 'platform')
    end
  end

  describe 'single instance deployment' do
    it 'works with instance_count 1' do
      result = lb_context.elastic_load_balancer(:web, minimal_lb_config.merge(instance_count: 1))
      expect(result[:haproxy_servers].size).to eq(1)
    end
  end

  describe 'multiple backends' do
    it 'includes all backend entries' do
      config = minimal_lb_config.merge(
        backends: [
          { name: 'node-1', address: '10.0.0.1', port: 30080 },
          { name: 'node-2', address: '10.0.0.2', port: 30080 },
          { name: 'node-3', address: '10.0.0.3', port: 30080 }
        ]
      )
      lb_context.elastic_load_balancer(:web, config)
      haproxy = lb_context.created_resources.find { |r| r[:name] == :web_haproxy_0 }
      expect(haproxy[:attrs][:user_data]).to include('10.0.0.1')
      expect(haproxy[:attrs][:user_data]).to include('10.0.0.2')
      expect(haproxy[:attrs][:user_data]).to include('10.0.0.3')
    end
  end
end
