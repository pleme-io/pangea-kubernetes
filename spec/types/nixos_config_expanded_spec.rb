# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::NixOSConfig, 'expanded fields' do
  describe 'new attribute defaults' do
    subject { described_class.new({}) }

    it 'defaults k3s to nil' do
      expect(subject.k3s).to be_nil
    end

    it 'defaults kubernetes to nil' do
      expect(subject.kubernetes).to be_nil
    end

    it 'defaults secrets to nil' do
      expect(subject.secrets).to be_nil
    end
  end

  describe 'backwards compatibility' do
    it 'existing callers still work without new fields' do
      config = described_class.new(
        image_id: 'ami-nixos',
        flake_url: 'github:pleme-io/nix#nixosConfigurations.k3s'
      )
      expect(config.image_id).to eq('ami-nixos')
      expect(config.flake_url).to start_with('github:')
    end
  end

  describe 'with k3s config' do
    subject do
      described_class.new(
        image_id: 'ami-nixos',
        k3s: {
          cluster_cidr: '10.42.0.0/16',
          disable: %w[traefik],
          firewall: { enabled: true }
        }
      )
    end

    it 'creates K3sConfig instance' do
      expect(subject.k3s).to be_a(Pangea::Kubernetes::Types::K3sConfig)
    end

    it 'stores k3s values' do
      expect(subject.k3s.cluster_cidr).to eq('10.42.0.0/16')
      expect(subject.k3s.disable).to eq(%w[traefik])
    end

    it 'stores nested firewall' do
      expect(subject.k3s.firewall.enabled).to be true
    end
  end

  describe 'with kubernetes config' do
    subject do
      described_class.new(
        kubernetes: {
          cluster_cidr: '10.244.0.0/16',
          control_plane: { disable_kube_proxy: true },
          etcd: { data_dir: '/data/etcd' }
        }
      )
    end

    it 'creates VanillaKubernetesConfig instance' do
      expect(subject.kubernetes).to be_a(Pangea::Kubernetes::Types::VanillaKubernetesConfig)
    end

    it 'stores control plane config' do
      expect(subject.kubernetes.control_plane.disable_kube_proxy).to be true
    end
  end

  describe 'with secrets config' do
    subject do
      described_class.new(
        secrets: {
          flux_ssh_key_path: '/run/secrets/flux-key',
          sops_age_key_path: '/run/secrets/age-key'
        }
      )
    end

    it 'creates SecretsConfig instance' do
      expect(subject.secrets).to be_a(Pangea::Kubernetes::Types::SecretsConfig)
    end

    it 'stores path references' do
      expect(subject.secrets.flux_ssh_key_path).to eq('/run/secrets/flux-key')
    end
  end

  describe '#to_h with new fields' do
    it 'includes k3s hash when set' do
      config = described_class.new(k3s: { cluster_cidr: '10.42.0.0/16' })
      hash = config.to_h
      expect(hash[:k3s][:cluster_cidr]).to eq('10.42.0.0/16')
    end

    it 'includes kubernetes hash when set' do
      config = described_class.new(kubernetes: { cluster_cidr: '10.244.0.0/16' })
      hash = config.to_h
      expect(hash[:kubernetes][:cluster_cidr]).to eq('10.244.0.0/16')
    end

    it 'includes secrets hash when set' do
      config = described_class.new(secrets: { flux_ssh_key_path: '/run/secrets/key' })
      hash = config.to_h
      expect(hash[:secrets][:flux_ssh_key_path]).to eq('/run/secrets/key')
    end

    it 'omits nil configs' do
      hash = described_class.new({}).to_h
      expect(hash).not_to have_key(:k3s)
      expect(hash).not_to have_key(:kubernetes)
      expect(hash).not_to have_key(:secrets)
    end
  end
end
