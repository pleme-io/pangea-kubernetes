# frozen_string_literal: true

RSpec.describe 'NixOS backend parity' do
  include SynthesisTestHelpers

  let(:base_tags) { { KubernetesCluster: 'test', ManagedBy: 'Pangea' } }

  # All 4 NixOS backends should generate identical cloud-init JSON
  # for the same cluster configuration (cloud-init is cloud-agnostic)
  describe 'identical cloud-init across backends' do
    let(:k3s_configs) do
      {
        aws_nixos: Pangea::Kubernetes::Types::ClusterConfig.new(
          backend: :aws_nixos, kubernetes_version: '1.34', region: 'us-east-1',
          distribution: :k3s, profile: 'cilium-standard', distribution_track: '1.34',
          ami_id: 'ami-test', key_pair: 'test-key',
          node_pools: [{ name: :system, instance_types: ['t3.large'] }],
          network: { vpc_cidr: '10.0.0.0/16' },
          nixos: { k3s: { cluster_cidr: '10.42.0.0/16', disable: %w[traefik] } }
        ),
        gcp_nixos: Pangea::Kubernetes::Types::ClusterConfig.new(
          backend: :gcp_nixos, kubernetes_version: '1.34', region: 'us-central1',
          distribution: :k3s, profile: 'cilium-standard', distribution_track: '1.34',
          project: 'test-project', gce_image: 'nixos-test',
          node_pools: [{ name: :system, instance_types: ['n2-standard-4'] }],
          network: { vpc_cidr: '10.0.0.0/16' },
          nixos: { k3s: { cluster_cidr: '10.42.0.0/16', disable: %w[traefik] } }
        ),
        azure_nixos: Pangea::Kubernetes::Types::ClusterConfig.new(
          backend: :azure_nixos, kubernetes_version: '1.34', region: 'eastus',
          distribution: :k3s, profile: 'cilium-standard', distribution_track: '1.34',
          azure_image_id: '/subscriptions/.../nixos',
          node_pools: [{ name: :system, instance_types: ['Standard_D4s_v3'] }],
          network: { vpc_cidr: '10.0.0.0/16' },
          nixos: { k3s: { cluster_cidr: '10.42.0.0/16', disable: %w[traefik] } }
        ),
        hcloud: Pangea::Kubernetes::Types::ClusterConfig.new(
          backend: :hcloud, kubernetes_version: '1.34', region: 'nbg1',
          distribution: :k3s, profile: 'cilium-standard', distribution_track: '1.34',
          node_pools: [{ name: :system, instance_types: ['cx31'], ssh_keys: ['test'] }],
          network: { vpc_cidr: '10.0.0.0/16' },
          nixos: { image_id: 'nixos-24-05', k3s: { cluster_cidr: '10.42.0.0/16', disable: %w[traefik] } }
        )
      }
    end

    it 'all 4 backends produce cloud-init with k3s passthrough' do
      backends = {
        aws_nixos: Pangea::Kubernetes::Backends::AwsNixos,
        gcp_nixos: Pangea::Kubernetes::Backends::GcpNixos,
        azure_nixos: Pangea::Kubernetes::Backends::AzureNixos,
        hcloud: Pangea::Kubernetes::Backends::HcloudK3s
      }

      cloud_init_contents = {}

      backends.each do |name, backend|
        ctx = create_mock_context
        config = k3s_configs[name]
        tags = base_tags.merge(Backend: name.to_s)

        result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
        result.network = backend.create_network(ctx, :test, config, tags)
        result.iam = backend.create_iam(ctx, :test, config, tags)

        backend.create_cluster(ctx, :test, config, result, tags)

        # Find the control plane instance's user_data/cloud-init
        cp_resources = ctx.created_resources.select { |r| r[:name] == :test_cp_0 }
        cp = cp_resources.first
        cloud_init = cp[:attrs][:user_data] || cp[:attrs][:custom_data] || cp[:attrs].dig(:metadata, 'user-data')

        cloud_init_contents[name] = cloud_init
      end

      # All should contain the same k3s config
      cloud_init_contents.each do |name, content|
        expect(content).to include('"k3s"'), "#{name} should include k3s section"
        expect(content).to include('"cluster_cidr":"10.42.0.0/16"'), "#{name} should include cluster_cidr"
        expect(content).to include('"traefik"'), "#{name} should include disable list"
        expect(content).to include('"distribution":"k3s"'), "#{name} should have k3s distribution"
        expect(content).to include('"profile":"cilium-standard"'), "#{name} should have cilium-standard profile"
      end
    end
  end

  describe 'all backends extend NixosBase' do
    it 'AwsNixos responds to base_firewall_ports' do
      expect(Pangea::Kubernetes::Backends::AwsNixos).to respond_to(:base_firewall_ports)
    end

    it 'GcpNixos responds to base_firewall_ports' do
      expect(Pangea::Kubernetes::Backends::GcpNixos).to respond_to(:base_firewall_ports)
    end

    it 'AzureNixos responds to base_firewall_ports' do
      expect(Pangea::Kubernetes::Backends::AzureNixos).to respond_to(:base_firewall_ports)
    end

    it 'HcloudK3s responds to base_firewall_ports' do
      expect(Pangea::Kubernetes::Backends::HcloudK3s).to respond_to(:base_firewall_ports)
    end

    it 'all respond to build_server_cloud_init' do
      [
        Pangea::Kubernetes::Backends::AwsNixos,
        Pangea::Kubernetes::Backends::GcpNixos,
        Pangea::Kubernetes::Backends::AzureNixos,
        Pangea::Kubernetes::Backends::HcloudK3s
      ].each do |backend|
        expect(backend).to respond_to(:build_server_cloud_init), "#{backend} should respond to build_server_cloud_init"
      end
    end
  end
end
