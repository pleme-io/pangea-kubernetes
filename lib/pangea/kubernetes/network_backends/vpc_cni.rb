# frozen_string_literal: true

module Pangea
  module Kubernetes
    module NetworkBackends
      # AWS VPC CNI — default EKS networking.
      # Pods get VPC IP addresses via ENI attachment.
      # No mesh, no mTLS, no L7 observability.
      module VpcCni
        include Base

        class << self
          def backend_name
            :vpc_cni
          end

          def compatible_backends
            [:aws]
          end

          def mesh_capable?
            false
          end

          def l7_observable?
            false
          end

          def nixos_profile
            nil # VPC CNI is EKS-only, no NixOS support
          end
        end
      end
    end
  end
end
