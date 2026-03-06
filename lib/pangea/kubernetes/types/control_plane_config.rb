# frozen_string_literal: true

require 'pangea/resources/types'

module Pangea
  module Kubernetes
    module Types
      # Control plane configuration for blackmatter-kubernetes NixOS modules.
      # Maps to `controlPlane.*` options in the NixOS module.
      # Only relevant for vanilla Kubernetes (k3s manages its own control plane).
      class ControlPlaneConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        # Extra args for kube-apiserver
        attribute :api_server_extra_args, T::Hash.default({}.freeze)

        # Extra SANs for the API server certificate
        attribute :api_server_extra_sans, T::Array.of(T::String).default([].freeze)

        # Extra args for kube-controller-manager
        attribute :controller_manager_extra_args, T::Hash.default({}.freeze)

        # Extra args for kube-scheduler
        attribute :scheduler_extra_args, T::Hash.default({}.freeze)

        # Disable kube-proxy (for CNIs that replace it, like Cilium)
        attribute :disable_kube_proxy, T::Bool.default(false)

        # Extra args for kube-proxy (when not disabled)
        attribute :kube_proxy_extra_args, T::Hash.default({}.freeze)

        # Use external etcd instead of co-located
        attribute :etcd_external, T::Bool.default(false)

        # External etcd endpoints
        attribute :etcd_endpoints, T::Array.of(T::String).default([].freeze)

        # External etcd CA file
        attribute :etcd_ca_file, T::String.optional.default(nil)

        # External etcd cert file
        attribute :etcd_cert_file, T::String.optional.default(nil)

        # External etcd key file
        attribute :etcd_key_file, T::String.optional.default(nil)

        def to_h
          hash = {}
          hash[:api_server_extra_args] = api_server_extra_args if api_server_extra_args.any?
          hash[:api_server_extra_sans] = api_server_extra_sans if api_server_extra_sans.any?
          hash[:controller_manager_extra_args] = controller_manager_extra_args if controller_manager_extra_args.any?
          hash[:scheduler_extra_args] = scheduler_extra_args if scheduler_extra_args.any?
          hash[:disable_kube_proxy] = disable_kube_proxy if disable_kube_proxy
          hash[:kube_proxy_extra_args] = kube_proxy_extra_args if kube_proxy_extra_args.any?
          hash[:etcd_external] = etcd_external if etcd_external
          hash[:etcd_endpoints] = etcd_endpoints if etcd_endpoints.any?
          hash[:etcd_ca_file] = etcd_ca_file if etcd_ca_file
          hash[:etcd_cert_file] = etcd_cert_file if etcd_cert_file
          hash[:etcd_key_file] = etcd_key_file if etcd_key_file
          hash
        end
      end
    end
  end
end
