# frozen_string_literal: true

require 'pangea/resources/types'

module Pangea
  module Kubernetes
    module Types
      # Secrets configuration for sops-nix path references.
      # These are file paths that sops-nix decrypts at boot time.
      # NEVER contains actual secret values — only filesystem paths.
      class SecretsConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        # Path to the FluxCD SSH deploy key (decrypted by sops-nix)
        attribute :flux_ssh_key_path, T::String.optional.default(nil)

        # Path to the FluxCD token (decrypted by sops-nix)
        attribute :flux_token_path, T::String.optional.default(nil)

        # Path to the SOPS age key (decrypted by sops-nix)
        attribute :sops_age_key_path, T::String.optional.default(nil)

        # Path to the K8s join token (decrypted by sops-nix)
        attribute :join_token_path, T::String.optional.default(nil)

        # Additional secret paths (name => path)
        attribute :extra_paths, T::Hash.default({}.freeze)

        def to_h
          hash = {}
          hash[:flux_ssh_key_path] = flux_ssh_key_path if flux_ssh_key_path
          hash[:flux_token_path] = flux_token_path if flux_token_path
          hash[:sops_age_key_path] = sops_age_key_path if sops_age_key_path
          hash[:join_token_path] = join_token_path if join_token_path
          hash[:extra_paths] = extra_paths if extra_paths.any?
          hash
        end
      end
    end
  end
end
