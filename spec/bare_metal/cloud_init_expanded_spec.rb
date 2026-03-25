# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::BareMetal::CloudInit, 'expanded fields' do
  describe 'k3s passthrough' do
    it 'includes k3s config in JSON when provided' do
      yaml = described_class.generate(
        cluster_name: 'test',
        distribution: :k3s,
        k3s: {
          cluster_cidr: '10.42.0.0/16',
          service_cidr: '10.43.0.0/16',
          disable: %w[traefik servicelb]
        }
      )
      expect(yaml).to include('"k3s"')
      expect(yaml).to include('"cluster_cidr":"10.42.0.0/16"')
      expect(yaml).to include('"service_cidr":"10.43.0.0/16"')
    end

    it 'omits k3s key when nil' do
      yaml = described_class.generate(cluster_name: 'test', distribution: :k3s)
      expect(yaml).not_to include('"k3s":{')
      expect(yaml).not_to include('"k3s":{"')
    end

    it 'omits k3s key when empty hash' do
      yaml = described_class.generate(cluster_name: 'test', distribution: :k3s, k3s: {})
      expect(yaml).not_to include('"k3s":{')
      expect(yaml).not_to include('"k3s":{"')
    end
  end

  describe 'kubernetes passthrough' do
    it 'includes kubernetes config in JSON when provided' do
      yaml = described_class.generate(
        cluster_name: 'test',
        distribution: :kubernetes,
        kubernetes: {
          cluster_cidr: '10.244.0.0/16',
          control_plane: {
            disable_kube_proxy: true
          }
        }
      )
      expect(yaml).to include('"kubernetes"')
      expect(yaml).to include('"cluster_cidr":"10.244.0.0/16"')
      expect(yaml).to include('"disable_kube_proxy":true')
    end

    it 'omits kubernetes key when nil' do
      yaml = described_class.generate(cluster_name: 'test', distribution: :kubernetes)
      expect(yaml).not_to include('"kubernetes":{')
    end
  end

  describe 'secrets passthrough' do
    it 'includes secrets path references in JSON' do
      yaml = described_class.generate(
        cluster_name: 'test',
        distribution: :k3s,
        secrets: {
          flux_ssh_key_path: '/run/secrets/flux-ssh-key',
          sops_age_key_path: '/run/secrets/sops-age-key'
        }
      )
      expect(yaml).to include('"secrets"')
      expect(yaml).to include('"flux_ssh_key_path":"/run/secrets/flux-ssh-key"')
    end

    it 'omits secrets when nil' do
      yaml = described_class.generate(cluster_name: 'test', distribution: :k3s)
      expect(yaml).not_to include('"secrets"')
    end

    it 'omits secrets when empty hash' do
      yaml = described_class.generate(cluster_name: 'test', distribution: :k3s, secrets: {})
      expect(yaml).not_to include('"secrets"')
    end
  end

  describe 'backwards compatibility' do
    it 'generates identical output without new params' do
      yaml_old = described_class.generate(
        cluster_name: 'test',
        distribution: :k3s,
        profile: 'cloud-server',
        distribution_track: '1.34',
        role: 'server',
        node_index: 0,
        cluster_init: true
      )

      expect(yaml_old.strip).to start_with('#!/usr/bin/env bash')
      expect(yaml_old).to include('"cluster_name":"test"')
      expect(yaml_old).to include('"distribution":"k3s"')
      expect(yaml_old).to include('"cluster_init":true')
      expect(yaml_old).not_to include('"k3s":{')
      expect(yaml_old).not_to include('"kubernetes":{')
      expect(yaml_old).not_to include('"secrets":{')
      expect(yaml_old).not_to include('"k3s":{"')
      expect(yaml_old).not_to include('"kubernetes":{"')
      expect(yaml_old).not_to include('"secrets":{"')
    end
  end

  describe 'key stringification' do
    it 'converts symbol keys to strings in nested hashes' do
      yaml = described_class.generate(
        cluster_name: 'test',
        distribution: :k3s,
        k3s: {
          firewall: { enabled: true, extra_tcp_ports: [8080] }
        }
      )
      # Symbol keys should be stringified in JSON
      expect(yaml).to include('"firewall"')
      expect(yaml).to include('"enabled":true')
      expect(yaml).to include('"extra_tcp_ports":[8080]')
    end
  end

  describe 'combined passthrough' do
    it 'includes k3s, fluxcd, and secrets together' do
      yaml = described_class.generate(
        cluster_name: 'production',
        distribution: :k3s,
        profile: 'cloud-server',
        distribution_track: '1.34',
        role: 'server',
        node_index: 0,
        cluster_init: true,
        fluxcd: { enabled: true, source_url: 'ssh://git@github.com/org/k8s.git' },
        k3s: { cluster_cidr: '10.42.0.0/16', disable: %w[traefik] },
        secrets: { flux_ssh_key_path: '/run/secrets/key' }
      )
      expect(yaml).to include('"fluxcd"')
      expect(yaml).to include('"k3s"')
      expect(yaml).to include('"secrets"')
      expect(yaml).to include('"cluster_name":"production"')
    end
  end
end
