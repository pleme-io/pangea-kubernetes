# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::SecretsConfig do
  describe 'defaults' do
    subject { described_class.new({}) }

    it 'defaults all paths to nil' do
      expect(subject.flux_ssh_key_path).to be_nil
      expect(subject.flux_token_path).to be_nil
      expect(subject.sops_age_key_path).to be_nil
      expect(subject.join_token_path).to be_nil
    end

    it 'defaults extra_paths to empty' do
      expect(subject.extra_paths).to eq({})
    end
  end

  describe 'path references (never values)' do
    subject do
      described_class.new(
        flux_ssh_key_path: '/run/secrets/flux-ssh-key',
        flux_token_path: '/run/secrets/flux-token',
        sops_age_key_path: '/run/secrets/sops-age-key',
        join_token_path: '/run/secrets/join-token',
        extra_paths: { 'registry_auth' => '/run/secrets/registry-auth' }
      )
    end

    it 'stores path references' do
      expect(subject.flux_ssh_key_path).to eq('/run/secrets/flux-ssh-key')
      expect(subject.sops_age_key_path).to eq('/run/secrets/sops-age-key')
    end

    it 'stores extra paths' do
      expect(subject.extra_paths).to eq({ 'registry_auth' => '/run/secrets/registry-auth' })
    end
  end

  describe '#to_h' do
    it 'omits nil paths' do
      hash = described_class.new({}).to_h
      expect(hash).to eq({})
    end

    it 'includes only set paths' do
      config = described_class.new(flux_ssh_key_path: '/run/secrets/ssh')
      hash = config.to_h
      expect(hash).to eq({ flux_ssh_key_path: '/run/secrets/ssh' })
    end

    it 'includes extra_paths when present' do
      config = described_class.new(extra_paths: { 'key' => '/path' })
      hash = config.to_h
      expect(hash[:extra_paths]).to eq({ 'key' => '/path' })
    end
  end
end
