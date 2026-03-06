# frozen_string_literal: true

require 'pangea/resources/types'

module Pangea
  module Kubernetes
    module Types
      # Kernel configuration for blackmatter-kubernetes NixOS modules.
      # Maps to `kernel.*` options in the NixOS module.
      class KernelConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        # Extra kernel modules to load at boot
        attribute :extra_modules, T::Array.of(T::String).default([].freeze)

        # Kernel sysctl parameters (key => value)
        attribute :sysctl, T::Hash.default({}.freeze)

        # Enable kernel hardening (sysctl defaults for K8s)
        attribute :hardening, T::Bool.default(true)

        def to_h
          hash = { hardening: hardening }
          hash[:extra_modules] = extra_modules if extra_modules.any?
          hash[:sysctl] = sysctl if sysctl.any?
          hash
        end
      end
    end
  end
end
