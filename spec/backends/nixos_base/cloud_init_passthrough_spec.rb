# frozen_string_literal: true

RSpec.describe 'NixosBase cloud-init passthrough' do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'test', Backend: 'aws_nixos', ManagedBy: 'Pangea' } }

  describe 'k3s distribution passthrough' do
    let(:config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        kubernetes_version: '1.34',
        region: 'us-east-1',
        distribution: :k3s,
        profile: 'cilium-standard',
        distribution_track: '1.34',
        ami_id: 'ami-test',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        network: { vpc_cidr: '10.0.0.0/16' },
        nixos: {
          k3s: {
            cluster_cidr: '10.42.0.0/16',
            service_cidr: '10.43.0.0/16',
            disable: %w[traefik servicelb],
            firewall: { enabled: true, extra_tcp_ports: [8080] }
          }
        }
      )
    end

    it 'includes k3s config in cloud-init JSON' do
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      result.network = Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      result.iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :test, config, result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :test_cp_0)
      user_data = cp_0[:attrs][:user_data]
      expect(user_data).to include('"k3s"')
      expect(user_data).to include('"cluster_cidr":"10.42.0.0/16"')
      expect(user_data).to include('"service_cidr":"10.43.0.0/16"')
      expect(user_data).to include('"traefik"')
    end

    it 'does not include kubernetes key for k3s distribution' do
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      result.network = Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      result.iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :test, config, result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :test_cp_0)
      user_data = cp_0[:attrs][:user_data]
      expect(user_data).not_to include('"kubernetes":{"')
    end
  end

  describe 'vanilla kubernetes passthrough' do
    let(:config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        kubernetes_version: '1.34',
        region: 'us-east-1',
        distribution: :kubernetes,
        profile: 'calico-standard',
        distribution_track: '1.34',
        ami_id: 'ami-test',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        network: { vpc_cidr: '10.0.0.0/16' },
        nixos: {
          kubernetes: {
            cluster_cidr: '10.244.0.0/16',
            control_plane: {
              disable_kube_proxy: true,
              api_server_extra_sans: ['api.example.com']
            }
          }
        }
      )
    end

    it 'includes kubernetes config in cloud-init JSON' do
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      result.network = Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      result.iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :test, config, result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :test_cp_0)
      user_data = cp_0[:attrs][:user_data]
      expect(user_data).to include('"kubernetes"')
      expect(user_data).to include('"cluster_cidr":"10.244.0.0/16"')
      expect(user_data).to include('"disable_kube_proxy":true')
    end

    it 'does not include k3s key for kubernetes distribution' do
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      result.network = Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      result.iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :test, config, result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :test_cp_0)
      user_data = cp_0[:attrs][:user_data]
      expect(user_data).not_to include('"k3s":{"')
    end
  end

  describe 'backwards compatibility (no nixos config)' do
    let(:config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        kubernetes_version: '1.34',
        region: 'us-east-1',
        distribution: :k3s,
        profile: 'cilium-standard',
        ami_id: 'ami-test',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        network: { vpc_cidr: '10.0.0.0/16' }
      )
    end

    it 'generates valid cloud-init without k3s/kubernetes/secrets sections' do
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      result.network = Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      result.iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :test, config, result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :test_cp_0)
      user_data = cp_0[:attrs][:user_data]
      expect(user_data).to include('#cloud-config')
      expect(user_data).to include('"distribution":"k3s"')
      expect(user_data).not_to include('"k3s":{"')
      expect(user_data).not_to include('"secrets":{"')
    end
  end
end
