# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::NixOSConfig do
  describe 'construction with defaults' do
    let(:config) { described_class.new({}) }

    it 'defaults image_id to nil' do
      expect(config.image_id).to be_nil
    end

    it 'defaults flake_url to nil' do
      expect(config.flake_url).to be_nil
    end

    it 'defaults extra_modules to empty array' do
      expect(config.extra_modules).to eq([])
    end

    it 'defaults sops_age_key_secret to nil' do
      expect(config.sops_age_key_secret).to be_nil
    end

    it 'defaults flux_ssh_key_secret to nil' do
      expect(config.flux_ssh_key_secret).to be_nil
    end

    it 'defaults k3s to nil' do
      expect(config.k3s).to be_nil
    end

    it 'defaults kubernetes to nil' do
      expect(config.kubernetes).to be_nil
    end

    it 'defaults secrets to nil' do
      expect(config.secrets).to be_nil
    end
  end

  describe 'with nested k3s config' do
    it 'accepts k3s config hash' do
      config = described_class.new(
        k3s: { disable: ['traefik'], flannel_backend: 'none' }
      )
      expect(config.k3s).not_to be_nil
      expect(config.k3s.disable).to eq(['traefik'])
    end
  end

  describe 'with nested secrets config' do
    it 'accepts secrets config hash' do
      config = described_class.new(
        secrets: { flux_ssh_key_path: '/run/secrets/flux-ssh' }
      )
      expect(config.secrets).not_to be_nil
      expect(config.secrets.flux_ssh_key_path).to eq('/run/secrets/flux-ssh')
    end
  end

  describe '#to_h' do
    it 'returns empty hash when all defaults' do
      config = described_class.new({})
      expect(config.to_h).to eq({})
    end

    it 'includes image_id when set' do
      config = described_class.new(image_id: 'ami-nixos')
      expect(config.to_h[:image_id]).to eq('ami-nixos')
    end

    it 'includes flake_url when set' do
      config = described_class.new(flake_url: 'github:org/flake')
      expect(config.to_h[:flake_url]).to eq('github:org/flake')
    end

    it 'includes extra_modules when non-empty' do
      config = described_class.new(extra_modules: ['mod1', 'mod2'])
      expect(config.to_h[:extra_modules]).to eq(['mod1', 'mod2'])
    end

    it 'omits extra_modules when empty' do
      config = described_class.new({})
      expect(config.to_h).not_to have_key(:extra_modules)
    end

    it 'includes k3s to_h when k3s is set' do
      config = described_class.new(k3s: { disable: ['traefik'] })
      expect(config.to_h[:k3s]).to be_a(Hash)
    end

    it 'includes secrets to_h when secrets is set' do
      config = described_class.new(secrets: { flux_ssh_key_path: '/path' })
      expect(config.to_h[:secrets]).to be_a(Hash)
    end
  end
end
