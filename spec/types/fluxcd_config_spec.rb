# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::FluxCDConfig do
  let(:minimal_attrs) { { source_url: 'ssh://git@github.com/org/k8s.git' } }

  describe 'construction with defaults' do
    let(:config) { described_class.new(minimal_attrs) }

    it 'defaults enabled to true' do
      expect(config.enabled).to be true
    end

    it 'defaults source_auth to ssh' do
      expect(config.source_auth).to eq('ssh')
    end

    it 'defaults source_interval to 1m0s' do
      expect(config.source_interval).to eq('1m0s')
    end

    it 'defaults reconcile_path to ./' do
      expect(config.reconcile_path).to eq('./')
    end

    it 'defaults reconcile_interval to 2m0s' do
      expect(config.reconcile_interval).to eq('2m0s')
    end

    it 'defaults sops_enabled to true' do
      expect(config.sops_enabled).to be true
    end

    it 'defaults source_branch to main' do
      expect(config.source_branch).to eq('main')
    end

    it 'defaults reconcile_prune to true' do
      expect(config.reconcile_prune).to be true
    end

    it 'defaults source_token_username to git' do
      expect(config.source_token_username).to eq('git')
    end

    it 'defaults known_hosts to nil' do
      expect(config.known_hosts).to be_nil
    end

    it 'defaults source_ssh_key_file to nil' do
      expect(config.source_ssh_key_file).to be_nil
    end

    it 'defaults source_token_file to nil' do
      expect(config.source_token_file).to be_nil
    end

    it 'defaults sops_age_key_file to nil' do
      expect(config.sops_age_key_file).to be_nil
    end
  end

  describe 'source_auth validation' do
    it 'accepts ssh' do
      config = described_class.new(minimal_attrs.merge(source_auth: 'ssh'))
      expect(config.source_auth).to eq('ssh')
    end

    it 'accepts token' do
      config = described_class.new(minimal_attrs.merge(source_auth: 'token'))
      expect(config.source_auth).to eq('token')
    end

    it 'rejects invalid source_auth' do
      expect {
        described_class.new(minimal_attrs.merge(source_auth: 'password'))
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe '#to_h' do
    let(:config) { described_class.new(minimal_attrs) }

    it 'includes all required fields' do
      hash = config.to_h
      expect(hash[:source_url]).to eq('ssh://git@github.com/org/k8s.git')
      expect(hash[:enabled]).to be true
      expect(hash[:source_auth]).to eq('ssh')
      expect(hash[:source_branch]).to eq('main')
      expect(hash[:reconcile_prune]).to be true
    end

    it 'omits known_hosts when nil' do
      expect(config.to_h).not_to have_key(:known_hosts)
    end

    it 'includes known_hosts when set' do
      config = described_class.new(minimal_attrs.merge(known_hosts: 'github.com ssh-rsa AAAA...'))
      expect(config.to_h[:known_hosts]).to start_with('github.com')
    end

    it 'omits source_ssh_key_file when nil' do
      expect(config.to_h).not_to have_key(:source_ssh_key_file)
    end

    it 'includes source_ssh_key_file when set' do
      config = described_class.new(minimal_attrs.merge(source_ssh_key_file: '/run/secrets/ssh'))
      expect(config.to_h[:source_ssh_key_file]).to eq('/run/secrets/ssh')
    end

    it 'omits source_token_file when nil' do
      expect(config.to_h).not_to have_key(:source_token_file)
    end

    it 'includes source_token_file when set' do
      config = described_class.new(minimal_attrs.merge(source_token_file: '/run/secrets/token'))
      expect(config.to_h[:source_token_file]).to eq('/run/secrets/token')
    end

    it 'omits sops_age_key_file when nil' do
      expect(config.to_h).not_to have_key(:sops_age_key_file)
    end

    it 'includes sops_age_key_file when set' do
      config = described_class.new(minimal_attrs.merge(sops_age_key_file: '/run/secrets/age'))
      expect(config.to_h[:sops_age_key_file]).to eq('/run/secrets/age')
    end
  end

  describe 'token-based auth configuration' do
    it 'supports full token config' do
      config = described_class.new(
        source_url: 'https://github.com/org/k8s.git',
        source_auth: 'token',
        source_token_file: '/run/secrets/gh-token',
        source_token_username: 'x-access-token',
        source_branch: 'develop'
      )
      expect(config.source_auth).to eq('token')
      expect(config.source_token_file).to eq('/run/secrets/gh-token')
      expect(config.source_token_username).to eq('x-access-token')
      expect(config.source_branch).to eq('develop')
    end
  end
end
