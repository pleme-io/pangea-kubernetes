# frozen_string_literal: true

RSpec.describe 'NixosBase secrets handling' do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'test', Backend: 'aws_nixos', ManagedBy: 'Pangea' } }

  describe 'secrets from FluxCD config' do
    let(:config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        kubernetes_version: '1.34',
        region: 'us-east-1',
        distribution: :k3s,
        profile: 'cilium-standard',
        ami_id: 'ami-test',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        network: { vpc_cidr: '10.0.0.0/16' },
        fluxcd: {
          source_url: 'ssh://git@github.com/org/k8s.git',
          source_ssh_key_file: '/run/secrets/flux-ssh-key',
          sops_age_key_file: '/run/secrets/sops-age-key'
        }
      )
    end

    it 'includes secrets path references in cloud-init' do
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      result.network = Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      result.iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :test, config, result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :test_cp_0)
      user_data = cp_0[:attrs][:user_data]
      expect(user_data).to include('"secrets"')
      expect(user_data).to include('"flux_ssh_key_path":"/run/secrets/flux-ssh-key"')
      expect(user_data).to include('"sops_age_key_path":"/run/secrets/sops-age-key"')
    end
  end

  describe 'secrets from NixOS config' do
    let(:config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        kubernetes_version: '1.34',
        region: 'us-east-1',
        distribution: :k3s,
        profile: 'cilium-standard',
        ami_id: 'ami-test',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        network: { vpc_cidr: '10.0.0.0/16' },
        nixos: {
          secrets: {
            flux_ssh_key_path: '/run/secrets/flux-key',
            sops_age_key_path: '/run/secrets/age-key',
            join_token_path: '/run/secrets/join-token'
          }
        }
      )
    end

    it 'includes secrets from nixos.secrets config' do
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      result.network = Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      result.iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :test, config, result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :test_cp_0)
      user_data = cp_0[:attrs][:user_data]
      expect(user_data).to include('"join_token_path":"/run/secrets/join-token"')
    end
  end

  describe 'no secrets configured' do
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

    it 'does not include secrets section in cloud-init' do
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      result.network = Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      result.iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :test, config, result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :test_cp_0)
      user_data = cp_0[:attrs][:user_data]
      expect(user_data).not_to include('"secrets"')
    end
  end

  describe 'FluxCD secrets take precedence over NixOS secrets' do
    let(:config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        kubernetes_version: '1.34',
        region: 'us-east-1',
        distribution: :k3s,
        profile: 'cilium-standard',
        ami_id: 'ami-test',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        network: { vpc_cidr: '10.0.0.0/16' },
        fluxcd: {
          source_url: 'ssh://git@github.com/org/k8s.git',
          source_ssh_key_file: '/run/secrets/fluxcd-ssh-key'
        },
        nixos: {
          secrets: {
            flux_ssh_key_path: '/run/secrets/nixos-ssh-key',
            join_token_path: '/run/secrets/join-token'
          }
        }
      )
    end

    it 'uses FluxCD ssh key path over NixOS one' do
      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      result.network = Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      result.iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :test, config, result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :test_cp_0)
      user_data = cp_0[:attrs][:user_data]
      # FluxCD source takes precedence
      expect(user_data).to include('/run/secrets/fluxcd-ssh-key')
      expect(user_data).not_to include('/run/secrets/nixos-ssh-key')
      # NixOS-only secrets still included
      expect(user_data).to include('/run/secrets/join-token')
    end
  end
end
