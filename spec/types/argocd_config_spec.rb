# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::ArgocdConfig do
  let(:minimal_attrs) { { repo_url: 'ssh://git@github.com/org/k8s.git' } }

  describe 'construction with defaults' do
    let(:config) { described_class.new(minimal_attrs) }

    it 'sets repo_url' do
      expect(config.repo_url).to eq('ssh://git@github.com/org/k8s.git')
    end

    it 'defaults enabled to true' do
      expect(config.enabled).to be true
    end

    it 'defaults target_revision to HEAD' do
      expect(config.target_revision).to eq('HEAD')
    end

    it 'defaults path to ./' do
      expect(config.path).to eq('./')
    end

    it 'defaults project to default' do
      expect(config.project).to eq('default')
    end

    it 'defaults sync_policy to automated' do
      expect(config.sync_policy).to eq('automated')
    end

    it 'defaults auto_prune to true' do
      expect(config.auto_prune).to be true
    end

    it 'defaults self_heal to true' do
      expect(config.self_heal).to be true
    end

    it 'defaults auth_type to ssh' do
      expect(config.auth_type).to eq('ssh')
    end

    it 'defaults ssh_key_file to nil' do
      expect(config.ssh_key_file).to be_nil
    end

    it 'defaults token_file to nil' do
      expect(config.token_file).to be_nil
    end

    it 'defaults token_username to git' do
      expect(config.token_username).to eq('git')
    end

    it 'defaults sops_enabled to false' do
      expect(config.sops_enabled).to be false
    end

    it 'defaults sops_age_key_file to nil' do
      expect(config.sops_age_key_file).to be_nil
    end
  end

  describe 'sync_policy validation' do
    it 'accepts automated' do
      config = described_class.new(minimal_attrs.merge(sync_policy: 'automated'))
      expect(config.sync_policy).to eq('automated')
    end

    it 'accepts manual' do
      config = described_class.new(minimal_attrs.merge(sync_policy: 'manual'))
      expect(config.sync_policy).to eq('manual')
    end

    it 'rejects invalid sync_policy' do
      expect {
        described_class.new(minimal_attrs.merge(sync_policy: 'never'))
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'auth_type validation' do
    it 'accepts ssh' do
      config = described_class.new(minimal_attrs.merge(auth_type: 'ssh'))
      expect(config.auth_type).to eq('ssh')
    end

    it 'accepts token' do
      config = described_class.new(minimal_attrs.merge(auth_type: 'token'))
      expect(config.auth_type).to eq('token')
    end

    it 'rejects invalid auth_type' do
      expect {
        described_class.new(minimal_attrs.merge(auth_type: 'password'))
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'missing required fields' do
    it 'raises when repo_url is missing' do
      expect {
        described_class.new({})
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'string key coercion' do
    it 'accepts string keys via transform_keys' do
      config = described_class.new('repo_url' => 'https://github.com/org/k8s.git')
      expect(config.repo_url).to eq('https://github.com/org/k8s.git')
    end
  end

  describe '#to_h' do
    it 'includes required fields' do
      config = described_class.new(minimal_attrs)
      hash = config.to_h
      expect(hash[:repo_url]).to eq('ssh://git@github.com/org/k8s.git')
      expect(hash[:enabled]).to be true
      expect(hash[:target_revision]).to eq('HEAD')
      expect(hash[:sync_policy]).to eq('automated')
      expect(hash[:auth_type]).to eq('ssh')
    end

    it 'omits ssh_key_file when nil' do
      config = described_class.new(minimal_attrs)
      expect(config.to_h).not_to have_key(:ssh_key_file)
    end

    it 'includes ssh_key_file when set' do
      config = described_class.new(minimal_attrs.merge(ssh_key_file: '/run/secrets/ssh'))
      expect(config.to_h[:ssh_key_file]).to eq('/run/secrets/ssh')
    end

    it 'omits token_file when nil' do
      config = described_class.new(minimal_attrs)
      expect(config.to_h).not_to have_key(:token_file)
    end

    it 'includes token_file when set' do
      config = described_class.new(minimal_attrs.merge(token_file: '/run/secrets/token'))
      expect(config.to_h[:token_file]).to eq('/run/secrets/token')
    end

    it 'omits sops_enabled when false' do
      config = described_class.new(minimal_attrs)
      expect(config.to_h).not_to have_key(:sops_enabled)
    end

    it 'includes sops_enabled when true' do
      config = described_class.new(minimal_attrs.merge(sops_enabled: true))
      expect(config.to_h[:sops_enabled]).to be true
    end

    it 'omits sops_age_key_file when nil' do
      config = described_class.new(minimal_attrs)
      expect(config.to_h).not_to have_key(:sops_age_key_file)
    end

    it 'includes sops_age_key_file when set' do
      config = described_class.new(minimal_attrs.merge(sops_age_key_file: '/run/secrets/age'))
      expect(config.to_h[:sops_age_key_file]).to eq('/run/secrets/age')
    end
  end

  describe 'full token-based config' do
    it 'constructs with all token-auth fields' do
      config = described_class.new(
        repo_url: 'https://github.com/org/k8s.git',
        auth_type: 'token',
        token_file: '/run/secrets/gh-token',
        token_username: 'x-access-token',
        sync_policy: 'manual',
        auto_prune: false,
        self_heal: false,
        sops_enabled: true,
        sops_age_key_file: '/run/secrets/age-key'
      )
      expect(config.auth_type).to eq('token')
      expect(config.token_file).to eq('/run/secrets/gh-token')
      expect(config.token_username).to eq('x-access-token')
      expect(config.auto_prune).to be false
      expect(config.self_heal).to be false
      hash = config.to_h
      expect(hash[:sops_enabled]).to be true
      expect(hash[:sops_age_key_file]).to eq('/run/secrets/age-key')
      expect(hash[:token_file]).to eq('/run/secrets/gh-token')
    end
  end
end
