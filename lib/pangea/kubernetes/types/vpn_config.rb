# frozen_string_literal: true

require 'pangea/resources/types'

module Pangea
  module Kubernetes
    module Types
      # Valid VPN profiles — must match kindling's VALID_VPN_PROFILES and
      # blackmatter-vpn's lib/profiles.nix
      VALID_VPN_PROFILES = %w[k8s-control-plane k8s-full site-to-site mesh].freeze

      # VPN peer configuration for WireGuard links.
      class VpnPeerConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :public_key, T::String
        attribute :endpoint, T::String.optional.default(nil)
        attribute :allowed_ips, T::Array.of(T::String).default([].freeze)
        attribute :persistent_keepalive, T::Coercible::Integer.optional.default(nil)
        attribute :preshared_key_file, T::String.optional.default(nil)

        def to_h
          hash = { public_key: public_key, allowed_ips: allowed_ips }
          hash[:endpoint] = endpoint if endpoint
          hash[:persistent_keepalive] = persistent_keepalive if persistent_keepalive
          hash[:preshared_key_file] = preshared_key_file if preshared_key_file
          hash
        end
      end

      # Per-link firewall configuration.
      class VpnFirewallConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :trust_interface, T::Bool.default(false)
        attribute :allowed_tcp_ports, T::Array.of(T::Coercible::Integer).default([].freeze)
        attribute :allowed_udp_ports, T::Array.of(T::Coercible::Integer).default([].freeze)
        attribute :incoming_udp_port, T::Coercible::Integer.optional.default(nil)

        def to_h
          hash = { trust_interface: trust_interface }
          hash[:allowed_tcp_ports] = allowed_tcp_ports if allowed_tcp_ports.any?
          hash[:allowed_udp_ports] = allowed_udp_ports if allowed_udp_ports.any?
          hash[:incoming_udp_port] = incoming_udp_port if incoming_udp_port
          hash
        end
      end

      # A single WireGuard VPN link.
      class VpnLinkConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :name, T::String
        attribute :private_key_file, T::String.optional.default(nil)
        attribute :listen_port, T::Coercible::Integer.optional.default(nil)
        attribute :address, T::String.optional.default(nil)
        attribute :profile, T::String.optional.default(nil)
        attribute :persistent_keepalive, T::Coercible::Integer.optional.default(nil)
        attribute :mtu, T::Coercible::Integer.optional.default(nil)
        attribute :peers, T::Array.of(VpnPeerConfig).default([].freeze)
        attribute :firewall, VpnFirewallConfig.optional.default(nil)

        def to_h
          hash = { name: name }
          hash[:private_key_file] = private_key_file if private_key_file
          hash[:listen_port] = listen_port if listen_port
          hash[:address] = address if address
          hash[:profile] = profile if profile
          hash[:persistent_keepalive] = persistent_keepalive if persistent_keepalive
          hash[:mtu] = mtu if mtu
          hash[:peers] = peers.map(&:to_h) if peers.any?
          hash[:firewall] = firewall.to_h if firewall
          hash
        end
      end

      # Top-level VPN configuration for a cluster.
      class VpnConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :require_liveness, T::Bool.default(false)
        attribute :links, T::Array.of(VpnLinkConfig).default([].freeze)

        def to_h
          return {} if links.empty?

          hash = { links: links.map(&:to_h) }
          hash[:require_liveness] = true if require_liveness
          hash
        end

        # Validate VPN configuration — mirrors kindling's structural checks.
        # Raises ArgumentError with all violations if any are found.
        def validate!
          return if links.empty?

          errors = []
          links.each_with_index do |link, i|
            ctx = "vpn.links[#{i}] (#{link.name})"

            errors << "#{ctx}: address is not a valid CIDR" if link.address && !valid_cidr?(link.address)
            errors << "#{ctx}: profile '#{link.profile}' is not valid" if link.profile && !VALID_VPN_PROFILES.include?(link.profile)

            if link.listen_port && link.listen_port != 0 && (link.listen_port < 1024 || link.listen_port > 65_535)
              errors << "#{ctx}: listen_port #{link.listen_port} outside valid range (0 or 1024-65535)"
            end

            if link.mtu && (link.mtu < 1280 || link.mtu > 9000)
              errors << "#{ctx}: mtu #{link.mtu} outside valid range (1280-9000)"
            end

            link.peers.each_with_index do |peer, j|
              pctx = "#{ctx}.peers[#{j}]"
              errors << "#{pctx}: public_key does not look like a valid WireGuard key" if peer.public_key && !valid_wg_key?(peer.public_key)

              peer.allowed_ips.each do |ip|
                errors << "#{pctx}: allowed_ips entry '#{ip}' is not a valid CIDR" unless valid_cidr?(ip)
              end

              if peer.endpoint && !valid_endpoint?(peer.endpoint)
                errors << "#{pctx}: endpoint '#{peer.endpoint}' is not valid (expected host:port)"
              end
            end
          end

          return if errors.empty?

          raise ArgumentError,
                "VPN validation failed (#{errors.length} violation(s)):\n  - #{errors.join("\n  - ")}"
        end

        private

        def valid_cidr?(cidr)
          parts = cidr.split('/', 2)
          return false unless parts.length == 2

          ip_str, prefix_str = parts
          begin
            prefix = Integer(prefix_str, 10)
          rescue ArgumentError
            return false
          end

          require 'ipaddr'
          begin
            addr = IPAddr.new(ip_str)
          rescue IPAddr::InvalidAddressError
            return false
          end

          if addr.ipv4?
            prefix >= 0 && prefix <= 32
          else
            prefix >= 0 && prefix <= 128
          end
        end

        def valid_wg_key?(key)
          # WireGuard keys are 32 bytes base64-encoded = 44 characters ending with =
          key.match?(/\A[A-Za-z0-9+\/]{43}=\z/)
        end

        def valid_endpoint?(endpoint)
          # Handle IPv6: [host]:port
          if endpoint.start_with?('[')
            match = endpoint.match(/\A\[.+\]:(\d+)\z/)
            return false unless match

            port = match[1].to_i
            return port >= 1 && port <= 65_535
          end

          # IPv4/hostname: host:port
          parts = endpoint.rpartition(':')
          return false if parts[0].empty? || parts[2].empty?

          begin
            port = Integer(parts[2], 10)
          rescue ArgumentError
            return false
          end
          port >= 1 && port <= 65_535
        end
      end
    end
  end
end
