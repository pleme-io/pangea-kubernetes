# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::FluxCDConfig, 'expanded fields' do
  describe 'new attribute defaults' do
    subject { described_class.new(source_url: 'ssh://git@github.com/org/repo.git') }

    it 'defaults source_branch to main' do
      expect(subject.source_branch).to eq('main')
    end

    it 'defaults reconcile_prune to true' do
      expect(subject.reconcile_prune).to be true
    end

    it 'defaults known_hosts to nil' do
      expect(subject.known_hosts).to be_nil
    end

    it 'defaults source_ssh_key_file to nil' do
      expect(subject.source_ssh_key_file).to be_nil
    end

    it 'defaults source_token_file to nil' do
      expect(subject.source_token_file).to be_nil
    end

    it 'defaults source_token_username to git' do
      expect(subject.source_token_username).to eq('git')
    end

    it 'defaults sops_age_key_file to nil' do
      expect(subject.sops_age_key_file).to be_nil
    end
  end

  describe 'backwards compatibility' do
    it 'existing callers still work without new fields' do
      config = described_class.new(source_url: 'ssh://git@github.com/org/repo.git')
      expect(config.enabled).to be true
      expect(config.source_auth).to eq('ssh')
      expect(config.source_interval).to eq('1m0s')
    end
  end

  describe 'full configuration with new fields' do
    subject do
      described_class.new(
        source_url: 'ssh://git@github.com/org/k8s.git',
        source_branch: 'production',
        reconcile_prune: false,
        known_hosts: 'github.com ssh-ed25519 AAAA...',
        source_ssh_key_file: '/run/secrets/flux-ssh-key',
        sops_age_key_file: '/run/secrets/sops-age-key'
      )
    end

    it 'stores new fields' do
      expect(subject.source_branch).to eq('production')
      expect(subject.reconcile_prune).to be false
      expect(subject.known_hosts).to start_with('github.com')
      expect(subject.source_ssh_key_file).to eq('/run/secrets/flux-ssh-key')
    end
  end

  describe '#to_h with new fields' do
    it 'always includes source_branch and reconcile_prune' do
      config = described_class.new(source_url: 'ssh://git@github.com/org/repo.git')
      hash = config.to_h
      expect(hash[:source_branch]).to eq('main')
      expect(hash[:reconcile_prune]).to be true
      expect(hash[:source_token_username]).to eq('git')
    end

    it 'omits nil optional fields' do
      config = described_class.new(source_url: 'ssh://git@github.com/org/repo.git')
      hash = config.to_h
      expect(hash).not_to have_key(:known_hosts)
      expect(hash).not_to have_key(:source_ssh_key_file)
      expect(hash).not_to have_key(:source_token_file)
      expect(hash).not_to have_key(:sops_age_key_file)
    end

    it 'includes set optional fields' do
      config = described_class.new(
        source_url: 'https://github.com/org/repo',
        source_auth: 'token',
        source_token_file: '/run/secrets/token',
        source_token_username: 'bot',
        sops_age_key_file: '/run/secrets/age-key'
      )
      hash = config.to_h
      expect(hash[:source_token_file]).to eq('/run/secrets/token')
      expect(hash[:source_token_username]).to eq('bot')
      expect(hash[:sops_age_key_file]).to eq('/run/secrets/age-key')
    end
  end
end
