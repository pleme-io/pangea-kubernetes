# frozen_string_literal: true

RSpec.describe 'NixosBase bootstrap secrets handling' do
  let(:backend) { Pangea::Kubernetes::Backends::AwsNixos }

  let(:base_attrs) do
    {
      backend: :aws_nixos,
      region: 'us-east-1',
      ami_id: 'ami-test',
      key_pair: 'test-key',
      node_pools: [{ name: :system, instance_types: ['t3.large'], min_size: 1, max_size: 3 }],
      network: { vpc_cidr: '10.0.0.0/16' }
    }
  end

  describe '#build_bootstrap_secrets' do
    it 'returns nil for empty bootstrap_secrets' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      result = backend.build_bootstrap_secrets(config)
      expect(result).to be_nil
    end

    it 'returns nil when bootstrap_secrets is not a Hash' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      allow(config).to receive(:bootstrap_secrets).and_return(nil)
      result = backend.build_bootstrap_secrets(config)
      expect(result).to be_nil
    end

    it 'returns nil when all values are empty strings' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(bootstrap_secrets: { sops_age_key: '', flux_github_token: '' })
      )
      result = backend.build_bootstrap_secrets(config)
      expect(result).to be_nil
    end

    it 'returns nil when all values are nil' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(bootstrap_secrets: { sops_age_key: nil })
      )
      result = backend.build_bootstrap_secrets(config)
      expect(result).to be_nil
    end

    it 'returns the hash when it has real values' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(bootstrap_secrets: { sops_age_key: 'AGE-SECRET-KEY-1...' })
      )
      result = backend.build_bootstrap_secrets(config)
      expect(result).to be_a(Hash)
      expect(result[:sops_age_key]).to eq('AGE-SECRET-KEY-1...')
    end

    it 'returns hash with mixed nil and real values' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(bootstrap_secrets: { sops_age_key: 'key', flux_github_token: nil })
      )
      result = backend.build_bootstrap_secrets(config)
      expect(result).to be_a(Hash)
      expect(result[:sops_age_key]).to eq('key')
    end
  end

  describe '#build_agent_bootstrap_secrets' do
    it 'returns nil when no bootstrap secrets' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      result = backend.build_agent_bootstrap_secrets(config)
      expect(result).to be_nil
    end

    it 'returns nil when bootstrap_secrets is not a Hash' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      allow(config).to receive(:bootstrap_secrets).and_return('invalid')
      result = backend.build_agent_bootstrap_secrets(config)
      expect(result).to be_nil
    end

    it 'extracts only agent-safe keys (k3s_server_token, nix_github_token)' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(bootstrap_secrets: {
          sops_age_key: 'AGE-KEY',
          flux_github_token: 'ghp_secret',
          k3s_server_token: 'K3S::server:token',
          nix_github_token: 'ghp_nix'
        })
      )
      result = backend.build_agent_bootstrap_secrets(config)
      expect(result).to be_a(Hash)
      expect(result[:k3s_server_token]).to eq('K3S::server:token')
      expect(result[:nix_github_token]).to eq('ghp_nix')
      expect(result).not_to have_key(:sops_age_key)
      expect(result).not_to have_key(:flux_github_token)
    end

    it 'returns nil when no agent keys exist' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(bootstrap_secrets: { sops_age_key: 'AGE-KEY' })
      )
      result = backend.build_agent_bootstrap_secrets(config)
      expect(result).to be_nil
    end
  end

  describe '#build_secrets_hash' do
    it 'returns nil when no secrets configured' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      result = backend.build_secrets_hash(config)
      expect(result).to be_nil
    end

    it 'extracts FluxCD secret paths' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(fluxcd: {
          source_url: 'ssh://git@github.com/org/k8s.git',
          source_ssh_key_file: '/run/secrets/flux-ssh',
          sops_age_key_file: '/run/secrets/age'
        })
      )
      result = backend.build_secrets_hash(config)
      expect(result[:flux_ssh_key_path]).to eq('/run/secrets/flux-ssh')
      expect(result[:sops_age_key_path]).to eq('/run/secrets/age')
    end

    it 'extracts NixOS secret paths' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(nixos: {
          secrets: {
            flux_ssh_key_path: '/run/secrets/nixos-flux',
            join_token_path: '/run/secrets/join'
          }
        })
      )
      result = backend.build_secrets_hash(config)
      expect(result[:flux_ssh_key_path]).to eq('/run/secrets/nixos-flux')
      expect(result[:join_token_path]).to eq('/run/secrets/join')
    end

    it 'gives FluxCD paths precedence over NixOS paths' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(
          fluxcd: {
            source_url: 'ssh://git@github.com/org/k8s.git',
            source_ssh_key_file: '/run/secrets/flux-ssh'
          },
          nixos: {
            secrets: {
              flux_ssh_key_path: '/run/secrets/nixos-flux'
            }
          }
        )
      )
      result = backend.build_secrets_hash(config)
      expect(result[:flux_ssh_key_path]).to eq('/run/secrets/flux-ssh')
    end
  end
end
