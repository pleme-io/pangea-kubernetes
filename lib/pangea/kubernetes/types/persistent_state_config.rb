# frozen_string_literal: true

require 'pangea/resources/types'

module Pangea
  module Kubernetes
    module Types
      # PersistentStateConfig — opt-in persistent state volume for a NixOS
      # cluster node, decoupled from the EC2 instance lifecycle.
      #
      # The aws_nixos backend (and any future backend that opts in) emits a
      # separately-managed cloud volume (e.g., aws_ebs_volume) tagged with
      # `<discovery_tag>=<cluster_name>`, with `lifecycle.prevent_destroy`
      # ON. The volume survives ASG sleep/wake, instance replacement, and
      # cluster recreation; only an explicit operator action can destroy it.
      #
      # At first boot the cluster bootstrap (kindling) discovers the
      # volume by tag, attaches it to the running instance, formats it if
      # blank, and mounts it at `mount_path`. Subsequent boots (after
      # sleep/wake or instance replacement) skip the format step and
      # remount the existing filesystem.
      #
      # AZ binding: an EBS volume is permanently bound to one AZ. When
      # `persistent_state` is set, the system node pool's ASG is
      # constrained to that AZ. Multi-AZ persistent state is a different
      # primitive (regional replication) and outside this type's scope.
      #
      # Mount path default `/var/lib/rancher/k3s` puts the k3s data dir
      # on the persistent volume, so cluster state (etcd, registrations,
      # workload state) survives instance churn.
      class PersistentStateConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        SUPPORTED_VOLUME_TYPES = %w[gp3 gp2 io1 io2 st1 sc1].freeze
        SUPPORTED_FILESYSTEMS  = %w[ext4 xfs].freeze

        # Volume size in GiB. EBS minimum 1 GiB for gp3/gp2; default 50.
        attribute :size_gb,
                  T::Coercible::Integer.constrained(gteq: 8).default(50)

        # EBS volume type. gp3 is the modern default.
        attribute :volume_type,
                  T::String.constrained(included_in: SUPPORTED_VOLUME_TYPES).default('gp3')

        # Mount path on the node. Default = k3s data dir, so cluster
        # state lives on the persistent volume.
        attribute :mount_path, T::String.default('/var/lib/rancher/k3s')

        # Filesystem to format on first boot. Subsequent boots remount
        # the existing fs without reformatting.
        attribute :filesystem,
                  T::String.constrained(included_in: SUPPORTED_FILESYSTEMS).default('ext4')

        # Tag key used to discover this cluster's persistent volume from
        # inside the instance. Tag value is always the cluster name.
        # Tunable so multiple persistent volumes per cluster (e.g. one
        # for k3s data, one for a workload PV) can coexist with
        # distinguishable discovery keys.
        attribute :discovery_tag, T::String.default('PersistentStateFor')

        # Whether to enable EBS encryption-at-rest. Default true.
        # Set false only for non-sensitive workloads where the marginal
        # cost matters.
        attribute :encrypted, T::Bool.default(true)

        # KMS key ARN/alias for encryption. nil = AWS-managed default key.
        attribute :kms_key_id, T::String.optional.default(nil)

        # Provisioned IOPS (gp3: 3000-16000; io1/io2 required). nil =
        # volume-type baseline.
        attribute :iops, T::Coercible::Integer.optional.default(nil)

        # Provisioned throughput in MiB/s (gp3 only: 125-1000). nil =
        # baseline.
        attribute :throughput, T::Coercible::Integer.optional.default(nil)

        # Availability zone for the volume. Must match the AZ where the
        # ASG instance launches. When nil, the backend derives it from
        # the first system-pool subnet's AZ.
        attribute :availability_zone, T::String.optional.default(nil)

        def to_h
          hash = {
            size_gb: size_gb,
            volume_type: volume_type,
            mount_path: mount_path,
            filesystem: filesystem,
            discovery_tag: discovery_tag,
            encrypted: encrypted
          }
          hash[:kms_key_id] = kms_key_id if kms_key_id
          hash[:iops] = iops if iops
          hash[:throughput] = throughput if throughput
          hash[:availability_zone] = availability_zone if availability_zone
          hash
        end
      end
    end
  end
end
