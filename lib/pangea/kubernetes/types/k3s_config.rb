# frozen_string_literal: true

require 'pangea/resources/types'
require 'pangea/kubernetes/types/firewall_config'
require 'pangea/kubernetes/types/kernel_config'
require 'pangea/kubernetes/types/wait_for_dns_config'

module Pangea
  module Kubernetes
    module Types
      # K3s distribution configuration for blackmatter-kubernetes NixOS modules.
      # Maps to `services.blackmatter.k3s.*` options.
      # Covers all k3s-specific settings that NixOS modules expose.
      class K3sConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        # Cluster CIDR for pod networking
        attribute :cluster_cidr, T::String.optional.default(nil)

        # Service CIDR for service networking
        attribute :service_cidr, T::String.optional.default(nil)

        # Cluster DNS address
        attribute :cluster_dns, T::String.optional.default(nil)

        # Node name override
        attribute :node_name, T::String.optional.default(nil)

        # Node labels (key => value)
        attribute :node_labels, T::Hash.default({}.freeze)

        # Node taints (array of taint strings, e.g., "key=value:NoSchedule")
        attribute :node_taints, T::Array.of(T::String).default([].freeze)

        # Node IP address override
        attribute :node_ip, T::String.optional.default(nil)

        # Extra flags passed to k3s server/agent
        attribute :extra_flags, T::Array.of(T::String).default([].freeze)

        # Data directory for k3s
        attribute :data_dir, T::String.optional.default(nil)

        # Config file path for k3s
        attribute :config_path, T::String.optional.default(nil)

        # Environment file for k3s systemd service
        attribute :environment_file, T::String.optional.default(nil)

        # Containerd config template path
        attribute :containerd_config_template, T::String.optional.default(nil)

        # K3s components to disable (e.g., ['traefik', 'servicelb'])
        attribute :disable, T::Array.of(T::String).default([].freeze)

        # Disable the agent on server nodes
        attribute :disable_agent, T::Bool.default(false)

        # Extra kubelet args (key => value)
        attribute :extra_kubelet_config, T::Hash.default({}.freeze)

        # Extra kube-proxy args (key => value)
        attribute :extra_kube_proxy_config, T::Hash.default({}.freeze)

        # Auto-deploying manifests directory content
        attribute :manifests, T::Hash.default({}.freeze)

        # Firewall configuration
        attribute :firewall, FirewallConfig.optional.default(nil)

        # Kernel configuration
        attribute :kernel, KernelConfig.optional.default(nil)

        # DNS wait configuration
        attribute :wait_for_dns, WaitForDNSConfig.optional.default(nil)

        # Enable NVIDIA GPU support
        attribute :nvidia_enable, T::Bool.default(false)

        # Enable graceful node shutdown
        attribute :graceful_node_shutdown, T::Bool.default(true)

        def to_h
          hash = {}
          hash[:cluster_cidr] = cluster_cidr if cluster_cidr
          hash[:service_cidr] = service_cidr if service_cidr
          hash[:cluster_dns] = cluster_dns if cluster_dns
          hash[:node_name] = node_name if node_name
          hash[:node_labels] = node_labels if node_labels.any?
          hash[:node_taints] = node_taints if node_taints.any?
          hash[:node_ip] = node_ip if node_ip
          hash[:extra_flags] = extra_flags if extra_flags.any?
          hash[:data_dir] = data_dir if data_dir
          hash[:config_path] = config_path if config_path
          hash[:environment_file] = environment_file if environment_file
          hash[:containerd_config_template] = containerd_config_template if containerd_config_template
          hash[:disable] = disable if disable.any?
          hash[:disable_agent] = disable_agent if disable_agent
          hash[:extra_kubelet_config] = extra_kubelet_config if extra_kubelet_config.any?
          hash[:extra_kube_proxy_config] = extra_kube_proxy_config if extra_kube_proxy_config.any?
          hash[:manifests] = manifests if manifests.any?
          hash[:firewall] = firewall.to_h if firewall
          hash[:kernel] = kernel.to_h if kernel
          hash[:wait_for_dns] = wait_for_dns.to_h if wait_for_dns
          hash[:nvidia_enable] = nvidia_enable if nvidia_enable
          hash[:graceful_node_shutdown] = graceful_node_shutdown
          hash
        end
      end
    end
  end
end
