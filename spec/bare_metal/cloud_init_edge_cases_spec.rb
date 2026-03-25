# frozen_string_literal: true

RSpec.describe 'CloudInit edge cases' do
  describe Pangea::Kubernetes::BareMetal::CloudInit do
    describe 'role normalization for vanilla kubernetes' do
      it 'preserves control-plane role as-is for kubernetes distribution' do
        result = described_class.generate(
          cluster_name: 'test',
          distribution: :kubernetes,
          profile: 'calico-standard',
          distribution_track: '1.34',
          role: 'control-plane',
          node_index: 0,
          cluster_init: true
        )
        expect(result).to include('"role":"control-plane"')
      end

      it 'preserves worker role as-is for kubernetes distribution' do
        result = described_class.generate(
          cluster_name: 'test',
          distribution: :kubernetes,
          profile: 'calico-standard',
          distribution_track: '1.34',
          role: 'worker',
          node_index: 0,
          cluster_init: false
        )
        expect(result).to include('"role":"worker"')
      end

      it 'does not normalize roles for k3s distribution' do
        result = described_class.generate(
          cluster_name: 'test',
          distribution: :k3s,
          profile: 'cilium-standard',
          distribution_track: '1.34',
          role: 'server',
          node_index: 0,
          cluster_init: true
        )
        expect(result).to include('"role":"server"')
      end

      it 'preserves agent role for k3s distribution' do
        result = described_class.generate(
          cluster_name: 'test',
          distribution: :k3s,
          profile: 'cilium-standard',
          distribution_track: '1.34',
          role: 'agent',
          node_index: 0,
          cluster_init: false
        )
        expect(result).to include('"role":"agent"')
      end
    end

    describe 'fluxcd config inclusion' do
      it 'excludes fluxcd when nil' do
        result = described_class.generate(
          cluster_name: 'test',
          distribution: :k3s,
          profile: 'cilium-standard',
          distribution_track: '1.34',
          role: 'server',
          node_index: 0,
          cluster_init: true,
          fluxcd: nil
        )
        expect(result).not_to include('fluxcd')
      end

      it 'includes full fluxcd config when provided' do
        fluxcd = {
          enabled: true,
          source_url: 'ssh://git@github.com/org/k8s.git',
          source_auth: 'ssh',
          reconcile_path: 'clusters/prod',
          sops_enabled: true
        }
        result = described_class.generate(
          cluster_name: 'test',
          distribution: :k3s,
          profile: 'cilium-standard',
          distribution_track: '1.34',
          role: 'server',
          node_index: 0,
          cluster_init: true,
          fluxcd: fluxcd
        )
        expect(result).to include('"fluxcd"')
        expect(result).to include('"source_url"')
        expect(result).to include('"source_auth":"ssh"')
        expect(result).to include('"reconcile_path":"clusters/prod"')
        expect(result).to include('"sops_enabled":true')
      end
    end

    describe 'node_index variations' do
      it 'handles node_index > 0 for server role' do
        result = described_class.generate(
          cluster_name: 'test',
          distribution: :k3s,
          profile: 'cilium-standard',
          distribution_track: '1.34',
          role: 'server',
          node_index: 5,
          cluster_init: false
        )
        expect(result).to include('"node_index":5')
      end
    end

    describe 'bootstrap via nix run' do
      it 'uses nix run github:pleme-io/kindling instead of systemctl' do
        result = described_class.generate(cluster_name: 'test')
        expect(result).to include('nix')
        expect(result).to include('nix-command flakes')
        expect(result).to include('github:pleme-io/kindling')
        expect(result).to include('server')
        expect(result).to include('bootstrap')
        expect(result).to include('/etc/pangea/cluster-config.json')
        expect(result).not_to include('systemctl')
      end
    end

    describe 'default parameters' do
      it 'uses default distribution (k3s)' do
        result = described_class.generate(
          cluster_name: 'test'
        )
        expect(result).to include('"distribution":"k3s"')
      end

      it 'uses default profile (cilium-standard)' do
        result = described_class.generate(
          cluster_name: 'test'
        )
        expect(result).to include('"profile":"cilium-standard"')
      end

      it 'uses default distribution_track (1.34)' do
        result = described_class.generate(
          cluster_name: 'test'
        )
        expect(result).to include('"distribution_track":"1.34"')
      end

      it 'uses default role (server)' do
        result = described_class.generate(
          cluster_name: 'test'
        )
        expect(result).to include('"role":"server"')
      end

      it 'uses default cluster_init (false)' do
        result = described_class.generate(
          cluster_name: 'test'
        )
        expect(result).to include('"cluster_init":false')
      end
    end
  end
end
