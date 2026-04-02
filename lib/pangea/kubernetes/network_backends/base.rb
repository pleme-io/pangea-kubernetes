# frozen_string_literal: true

module Pangea
  module Kubernetes
    module NetworkBackends
      # Contract interface for network backends. Each backend module
      # provides CNI-specific infrastructure (IAM, config) and metadata.
      #
      # Network backends are orthogonal to compute backends — you can
      # combine any network backend with any compatible compute backend:
      #
      #   | Network Backend | EKS | K3s/NixOS | mTLS | L7 Obs | eBPF |
      #   |----------------|-----|-----------|------|--------|------|
      #   | vpc_cni        | ✅  | ❌        | ❌   | ❌     | ❌   |
      #   | cilium_eni     | ✅  | ❌        | ✅   | ✅     | ✅   |
      #   | cilium_overlay | ✅  | ✅        | ✅   | ✅     | ✅   |
      #   | calico         | ✅  | ✅        | ❌   | ❌     | partial |
      #   | flannel        | ❌  | ✅        | ❌   | ❌     | ❌   |
      #
      module Base
        def self.included(base)
          base.extend(ClassMethods)
        end

        module ClassMethods
          # @return [Symbol] Backend identifier (:vpc_cni, :cilium, :calico, :flannel)
          def backend_name
            raise NotImplementedError, "#{self} must implement .backend_name"
          end

          # @return [Array<Symbol>] Compatible compute backends (:aws, :gcp, :azure, :hcloud, etc.)
          def compatible_backends
            raise NotImplementedError, "#{self} must implement .compatible_backends"
          end

          # @return [Boolean] Whether this backend provides service mesh capabilities
          def mesh_capable?
            false
          end

          # @return [Boolean] Whether this backend provides L7 observability (e.g., Hubble)
          def l7_observable?
            false
          end

          # Create cloud-level IAM resources for the CNI (e.g., IRSA for Cilium operator).
          # Returns nil if no cloud IAM is needed.
          #
          # @param ctx [Object] Synthesizer context
          # @param name [Symbol] Cluster name
          # @param config [Hash] Network configuration
          # @param tags [Hash] Resource tags
          # @return [Hash, nil] IAM resources created
          def create_network_iam(_ctx, _name, _config, _tags)
            nil # Most network backends don't need cloud IAM
          end

          # Return the NixOS/blackmatter-kubernetes profile name for this backend.
          # Used by NixOS backends in cloud-init to select the correct CNI config.
          #
          # @return [String, nil] Profile name (e.g., 'cilium-mesh', 'flannel-production')
          def nixos_profile
            nil # Managed backends (EKS/GKE/AKS) don't use NixOS profiles
          end

          # Return Helm values or configuration to be passed to the GitOps layer.
          # This is what gets deployed via FluxCD HelmRelease.
          #
          # @param config [Hash] Network configuration
          # @return [Hash] Configuration for the network backend's Helm chart
          def helm_values(_config)
            {}
          end
        end
      end
    end
  end
end
