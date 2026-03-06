# frozen_string_literal: true

require 'pangea/resources/types'

module Pangea
  module Kubernetes
    module Types
      # Etcd configuration for blackmatter-kubernetes NixOS modules.
      # Maps to `etcd.*` options in the NixOS module.
      # Only relevant for vanilla Kubernetes (k3s embeds etcd).
      class EtcdConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        # Initial cluster state: 'new' or 'existing'
        attribute :initial_cluster_state, T::String.constrained(
          included_in: %w[new existing]
        ).default('new')

        # Data directory for etcd
        attribute :data_dir, T::String.default('/var/lib/etcd')

        # External etcd endpoints (when not co-located with control plane)
        attribute :external_endpoints, T::Array.of(T::String).default([].freeze)

        # Snapshot count before compaction
        attribute :snapshot_count, T::Coercible::Integer.optional.default(nil)

        # Heartbeat interval in ms
        attribute :heartbeat_interval, T::Coercible::Integer.optional.default(nil)

        # Election timeout in ms
        attribute :election_timeout, T::Coercible::Integer.optional.default(nil)

        # CA certificate file path (for external etcd)
        attribute :ca_file, T::String.optional.default(nil)

        # Client certificate file path (for external etcd)
        attribute :cert_file, T::String.optional.default(nil)

        # Client key file path (for external etcd)
        attribute :key_file, T::String.optional.default(nil)

        def external?
          external_endpoints.any?
        end

        def to_h
          hash = {
            initial_cluster_state: initial_cluster_state,
            data_dir: data_dir
          }
          hash[:external_endpoints] = external_endpoints if external_endpoints.any?
          hash[:snapshot_count] = snapshot_count if snapshot_count
          hash[:heartbeat_interval] = heartbeat_interval if heartbeat_interval
          hash[:election_timeout] = election_timeout if election_timeout
          hash[:ca_file] = ca_file if ca_file
          hash[:cert_file] = cert_file if cert_file
          hash[:key_file] = key_file if key_file
          hash
        end
      end
    end
  end
end
