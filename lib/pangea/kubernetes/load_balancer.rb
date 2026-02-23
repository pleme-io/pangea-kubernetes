# frozen_string_literal: true

# Copyright 2025 The Pangea Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'pangea/kubernetes/types'
require 'pangea/kubernetes/bare_metal/cloud_init'

module Pangea
  module Kubernetes
    # Elastic load balancer tier composition.
    #
    # Two-tier architecture:
    #   Tier 1 (External): Fleet of NixOS HAProxy VMs behind Hetzner Cloud LB
    #   Tier 2 (In-Cluster): Cilium eBPF (L4) + Istio Gateway (L7)
    #
    # Traffic flow:
    #   DNS → Hetzner Cloud LB → NixOS HAProxy fleet → K8s NodePort → Istio Gateway
    #
    # For bare metal: replace Hetzner Cloud LB with NixOS BIRD BGP + keepalived VRRP
    module LoadBalancer
      # Create an elastic load balancer tier for a Kubernetes cluster.
      #
      # @param name [Symbol] LB tier name
      # @param attributes [Hash] Load balancer configuration (see Types::LoadBalancerConfig)
      # @return [Hash] Created resource references
      def elastic_load_balancer(name, attributes = {})
        config = Types::LoadBalancerConfig.new(attributes)
        result = {}

        tags = {
          LoadBalancer: name.to_s,
          Mode: config.mode,
          ManagedBy: 'Pangea'
        }.merge(config.tags)

        hcloud_labels = tags.transform_keys { |k| k.to_s.downcase.gsub(/[^a-z0-9_]/, '_') }

        # Create HAProxy VMs
        result[:haproxy_servers] = create_haproxy_fleet(name, config, hcloud_labels)

        # Create Hetzner Cloud LB in front of HAProxy fleet (managed mode)
        unless config.bare_metal?
          result[:cloud_lb] = create_hetzner_cloud_lb(name, config, result[:haproxy_servers], hcloud_labels)
        end

        result
      end

      private

      def create_haproxy_fleet(name, config, labels)
        servers = []

        config.instance_count.times do |idx|
          user_data = generate_haproxy_cloud_init(name, config, idx)

          server = hcloud_server(
            :"#{name}_haproxy_#{idx}",
            name: "#{name}-haproxy-#{idx}",
            server_type: config.instance_type,
            image: 'ubuntu-24.04',
            location: config.region,
            user_data: user_data,
            labels: labels.merge(
              'role' => 'haproxy',
              'node_index' => idx.to_s
            )
          )

          servers << server
        end

        servers
      end

      def create_hetzner_cloud_lb(name, config, haproxy_servers, labels)
        lb = hcloud_load_balancer(
          :"#{name}_cloud_lb",
          name: "#{name}-cloud-lb",
          load_balancer_type: 'lb11',
          location: config.region,
          labels: labels
        )

        # Add targets (HAProxy servers)
        haproxy_servers.each_with_index do |server, idx|
          hcloud_load_balancer_target(
            :"#{name}_lb_target_#{idx}",
            load_balancer_id: lb.id,
            type: 'server',
            server_id: server.id
          )
        end

        # Add services for each frontend port
        config.frontend_ports.each do |port|
          protocol = port == 443 ? 'https' : 'http'
          hcloud_load_balancer_service(
            :"#{name}_lb_service_#{port}",
            load_balancer_id: lb.id,
            protocol: protocol,
            listen_port: port,
            destination_port: port,
            health_check: {
              protocol: 'tcp',
              port: port,
              interval: config.health_check_interval.to_i
            }
          )
        end

        lb
      end

      def generate_haproxy_cloud_init(name, config, index)
        haproxy_config = {
          'cluster_name' => name.to_s,
          'role' => 'haproxy',
          'node_index' => index,
          'mode' => config.mode,
          'max_connections' => config.max_connections,
          'frontend_ports' => config.frontend_ports,
          'backends' => config.backends
        }

        if config.bare_metal?
          haproxy_config['bgp_asn'] = config.bgp_asn if config.bgp_asn
          haproxy_config['bgp_neighbor'] = config.bgp_neighbor if config.bgp_neighbor
          haproxy_config['vrrp_interface'] = config.vrrp_interface if config.vrrp_interface
          haproxy_config['virtual_ips'] = config.virtual_ips if config.virtual_ips.any?
        end

        <<~YAML
          #cloud-config
          write_files:
            - path: /etc/pangea/haproxy-config.json
              content: '#{haproxy_config.to_json}'
              permissions: '0644'
          runcmd:
            - ['systemctl', 'start', 'pangea-haproxy-bootstrap']
        YAML
      end
    end
  end
end
