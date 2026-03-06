# frozen_string_literal: true

require 'pangea/resources/types'

module Pangea
  module Kubernetes
    module Types
      # Firewall configuration for blackmatter-kubernetes NixOS modules.
      # Maps to `firewall.*` options in the NixOS module.
      class FirewallConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        # Enable the firewall module
        attribute :enabled, T::Bool.default(true)

        # Additional TCP ports to open (beyond K8s defaults)
        attribute :extra_tcp_ports, T::Array.of(T::Coercible::Integer).default([].freeze)

        # Additional UDP ports to open (beyond K8s defaults)
        attribute :extra_udp_ports, T::Array.of(T::Coercible::Integer).default([].freeze)

        # Trusted source CIDRs for internal traffic
        attribute :trusted_cidrs, T::Array.of(T::String).default([].freeze)

        # Allow all intra-cluster traffic
        attribute :allow_intra_cluster, T::Bool.default(true)

        def to_h
          hash = { enabled: enabled }
          hash[:extra_tcp_ports] = extra_tcp_ports if extra_tcp_ports.any?
          hash[:extra_udp_ports] = extra_udp_ports if extra_udp_ports.any?
          hash[:trusted_cidrs] = trusted_cidrs if trusted_cidrs.any?
          hash[:allow_intra_cluster] = allow_intra_cluster
          hash
        end
      end
    end
  end
end
