# frozen_string_literal: true

require 'pangea/resources/types'

module Pangea
  module Kubernetes
    module Types
      # DNS wait configuration for blackmatter-kubernetes NixOS modules.
      # Maps to `waitForDNS.*` options in the NixOS module.
      class WaitForDNSConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        # Enable waiting for DNS resolution before bootstrap
        attribute :enabled, T::Bool.default(false)

        # DNS hostname to resolve before proceeding
        attribute :hostname, T::String.optional.default(nil)

        # Maximum wait time in seconds
        attribute :timeout_seconds, T::Coercible::Integer.constrained(gteq: 1).default(300)

        # Retry interval in seconds
        attribute :retry_interval, T::Coercible::Integer.constrained(gteq: 1).default(5)

        def to_h
          hash = { enabled: enabled }
          hash[:hostname] = hostname if hostname
          hash[:timeout_seconds] = timeout_seconds
          hash[:retry_interval] = retry_interval
          hash
        end
      end
    end
  end
end
