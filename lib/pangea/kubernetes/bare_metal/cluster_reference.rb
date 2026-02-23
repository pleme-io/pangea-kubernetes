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

module Pangea
  module Kubernetes
    module BareMetal
      # Synthetic cluster reference for unmanaged Kubernetes (k3s, kubeadm, etc.).
      # Unlike managed K8s (EKS, GKE, AKS), bare-metal clusters don't have a
      # single terraform resource representing the cluster. This provides a
      # compatible interface using the primary control plane server.
      class ClusterReference
        attr_reader :name, :control_plane_servers, :worker_servers, :config

        def initialize(name:, control_plane_servers:, worker_servers: [], config: {})
          @name = name
          @control_plane_servers = control_plane_servers
          @worker_servers = worker_servers
          @config = config
        end

        # Primary control plane endpoint
        def endpoint
          primary_server&.ipv4_address
        end

        # k3s API port
        def api_port
          6443
        end

        # Full API endpoint URL
        def api_endpoint
          "https://#{endpoint}:#{api_port}"
        end

        # All node IPs (control plane + workers)
        def all_node_ips
          (control_plane_servers + worker_servers).map(&:ipv4_address)
        end

        def to_h
          {
            name: name,
            endpoint: endpoint,
            api_port: api_port,
            control_plane_count: control_plane_servers.size,
            worker_count: worker_servers.size
          }
        end

        private

        def primary_server
          control_plane_servers.first
        end
      end
    end
  end
end
