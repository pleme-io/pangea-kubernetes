# frozen_string_literal: true

module Pangea
  module Kubernetes
    module Types
      # ArgoCD GitOps bootstrap configuration.
      #
      # Parallel to FluxCDConfig — provides the same role but for ArgoCD.
      # The bootstrap service writes ArgoCD manifests to the k3s auto-deploy
      # directory at boot, then creates git auth credentials after API is ready.
      class ArgocdConfig < Pangea::Resources::BaseAttributes
        transform_keys(&:to_sym)

        attribute :enabled, T::Bool.default(true)
        attribute :repo_url, T::String
        attribute :target_revision, T::String.default('HEAD')
        attribute :path, T::String.default('./')
        attribute :project, T::String.default('default')
        attribute :sync_policy, T::String.constrained(included_in: %w[automated manual]).default('automated')
        attribute :auto_prune, T::Bool.default(true)
        attribute :self_heal, T::Bool.default(true)

        # Auth
        attribute :auth_type, T::String.constrained(included_in: %w[ssh token]).default('ssh')
        attribute :ssh_key_file, T::String.optional.default(nil)
        attribute :token_file, T::String.optional.default(nil)
        attribute :token_username, T::String.default('git')

        # SOPS
        attribute :sops_enabled, T::Bool.default(false)
        attribute :sops_age_key_file, T::String.optional.default(nil)

        def to_h
          hash = {
            enabled: enabled,
            repo_url: repo_url,
            target_revision: target_revision,
            path: path,
            project: project,
            sync_policy: sync_policy,
            auto_prune: auto_prune,
            self_heal: self_heal,
            auth_type: auth_type,
            token_username: token_username
          }
          hash[:ssh_key_file] = ssh_key_file if ssh_key_file
          hash[:token_file] = token_file if token_file
          hash[:sops_enabled] = sops_enabled if sops_enabled
          hash[:sops_age_key_file] = sops_age_key_file if sops_age_key_file
          hash
        end
      end
    end
  end
end
