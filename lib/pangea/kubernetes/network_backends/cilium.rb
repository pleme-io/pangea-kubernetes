# frozen_string_literal: true

module Pangea
  module Kubernetes
    module NetworkBackends
      # Cilium — eBPF-based CNI with service mesh and L7 observability.
      # Supports ENI mode (AWS VPC IPs) and overlay mode (VXLAN/Geneve).
      # Hubble provides per-request latency histograms without app instrumentation.
      module Cilium
        include Base

        class << self
          def backend_name
            :cilium
          end

          def compatible_backends
            %i[aws gcp azure hcloud aws_nixos gcp_nixos azure_nixos]
          end

          def mesh_capable?
            true
          end

          def l7_observable?
            true # Hubble
          end

          # IRSA for Cilium operator on EKS.
          def create_network_iam(ctx, name, config, tags)
            return nil unless config[:compute_backend] == :aws

            # Cilium operator needs permissions for ENI management
            ctx.extend(Pangea::Resources::AWS) unless ctx.respond_to?(:aws_iam_role)

            policy_doc = JSON.generate({
              Version: '2012-10-17',
              Statement: [{
                Effect: 'Allow',
                Action: [
                  'ec2:DescribeNetworkInterfaces',
                  'ec2:DescribeSubnets',
                  'ec2:DescribeVpcs',
                  'ec2:DescribeSecurityGroups',
                  'ec2:CreateNetworkInterface',
                  'ec2:AttachNetworkInterface',
                  'ec2:DeleteNetworkInterface',
                  'ec2:ModifyNetworkInterfaceAttribute',
                  'ec2:AssignPrivateIpAddresses',
                  'ec2:UnassignPrivateIpAddresses',
                  'ec2:CreateTags',
                ],
                Resource: '*',
              }],
            })

            policy = ctx.aws_iam_policy(:"#{name}-cilium-operator", {
              name: "#{name}-cilium-operator",
              policy: policy_doc,
              tags: tags.merge(Component: 'cilium'),
            })

            { policy: policy }
          end

          def nixos_profile
            'cilium-mesh'
          end

          def helm_values(config)
            mode = config[:cilium_mode] || :eni
            values = {
              'ipam' => { 'mode' => mode.to_s },
              'hubble' => {
                'enabled' => true,
                'relay' => { 'enabled' => true },
                'ui' => { 'enabled' => false }, # No GUI, MCP-queryable via Grafana
                'metrics' => {
                  'enabled' => [
                    'dns', 'drop', 'tcp', 'flow',
                    'icmp', 'http', 'port-distribution',
                    'httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload',
                  ],
                },
              },
              'prometheus' => { 'enabled' => true },
              'operator' => { 'prometheus' => { 'enabled' => true } },
            }

            # ENI mode: use AWS VPC IPs (compatible with existing /20 pod subnets)
            if mode == :eni
              values['eni'] = {
                'enabled' => true,
                'awsEnablePrefixDelegation' => true,
              }
              values['tunnel'] = 'disabled'
            end

            values
          end
        end
      end
    end
  end
end
