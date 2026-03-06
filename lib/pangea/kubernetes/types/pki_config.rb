# frozen_string_literal: true

require 'pangea/resources/types'

module Pangea
  module Kubernetes
    module Types
      # PKI configuration for blackmatter-kubernetes NixOS modules.
      # Maps to `pki.*` options in the NixOS module.
      # Controls certificate generation and distribution.
      class PKIConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        # PKI mode: 'auto' (generated), 'manual' (user-provided), or 'external' (cert-manager)
        attribute :mode, T::String.constrained(
          included_in: %w[auto manual external]
        ).default('auto')

        # Certificate validity period in days
        attribute :cert_validity_days, T::Coercible::Integer.constrained(gteq: 1).default(365)

        # CA certificate path (for manual mode)
        attribute :ca_cert_path, T::String.optional.default(nil)

        # CA key path (for manual mode)
        attribute :ca_key_path, T::String.optional.default(nil)

        # Additional SANs for the API server certificate
        attribute :api_server_extra_sans, T::Array.of(T::String).default([].freeze)

        # Certificate directory
        attribute :cert_dir, T::String.default('/etc/kubernetes/pki')

        def to_h
          hash = {
            mode: mode,
            cert_validity_days: cert_validity_days,
            cert_dir: cert_dir
          }
          hash[:ca_cert_path] = ca_cert_path if ca_cert_path
          hash[:ca_key_path] = ca_key_path if ca_key_path
          hash[:api_server_extra_sans] = api_server_extra_sans if api_server_extra_sans.any?
          hash
        end
      end
    end
  end
end
