# frozen_string_literal: true

RSpec.describe 'CloudInit output formats and passthrough' do
  describe Pangea::Kubernetes::BareMetal::CloudInit do
    describe 'dynamic node_index handling' do
      it 'generates IMDSv2 snippet when node_index is dynamic' do
        result = described_class.generate(
          cluster_name: 'test',
          node_index: 'dynamic'
        )
        expect(result).to include('IMDS_TOKEN')
        expect(result).to include('INSTANCE_ID')
        expect(result).to include('NODE_INDEX')
        expect(result).to include('169.254.169.254')
      end

      it 'includes sed replacement for dynamic sentinel' do
        result = described_class.generate(
          cluster_name: 'test',
          node_index: 'dynamic'
        )
        expect(result).to include('sed -i')
        expect(result).to include('node_index')
      end

      it 'does not include IMDSv2 snippet for static index' do
        result = described_class.generate(
          cluster_name: 'test',
          node_index: 0
        )
        expect(result).not_to include('IMDS_TOKEN')
        expect(result).not_to include('INSTANCE_ID')
      end

      it 'includes dynamic sentinel in JSON for dynamic index' do
        result = described_class.generate(
          cluster_name: 'test',
          node_index: 'dynamic'
        )
        expect(result).to include('"node_index":"dynamic"')
      end
    end

    describe 'argocd config passthrough' do
      it 'includes argocd config in JSON when provided' do
        argocd = {
          enabled: true,
          repo_url: 'https://github.com/org/k8s.git',
          target_revision: 'main',
          path: 'clusters/prod'
        }
        result = described_class.generate(
          cluster_name: 'test',
          argocd: argocd
        )
        expect(result).to include('"argocd"')
        expect(result).to include('"repo_url"')
        expect(result).to include('"target_revision":"main"')
      end

      it 'excludes argocd when nil' do
        result = described_class.generate(
          cluster_name: 'test',
          argocd: nil
        )
        expect(result).not_to include('"argocd"')
      end

      it 'excludes argocd when empty hash' do
        result = described_class.generate(
          cluster_name: 'test',
          argocd: {}
        )
        expect(result).not_to include('"argocd"')
      end

      it 'stringifies symbol keys in argocd config' do
        argocd = { repo_url: 'https://github.com/org/k8s.git' }
        result = described_class.generate(
          cluster_name: 'test',
          argocd: argocd
        )
        expect(result).to include('"repo_url"')
        expect(result).not_to include(':repo_url')
      end
    end

    describe 'VPN config passthrough' do
      it 'includes vpn config in JSON when provided' do
        vpn = { interface: 'wg0', address: '10.100.0.1/24', port: 51820 }
        result = described_class.generate(
          cluster_name: 'test',
          vpn: vpn
        )
        expect(result).to include('"vpn"')
        expect(result).to include('"interface"')
      end

      it 'excludes vpn when nil' do
        result = described_class.generate(
          cluster_name: 'test',
          vpn: nil
        )
        expect(result).not_to include('"vpn"')
      end

      it 'excludes vpn when empty hash' do
        result = described_class.generate(
          cluster_name: 'test',
          vpn: {}
        )
        expect(result).not_to include('"vpn"')
      end
    end

    describe 'secrets config passthrough' do
      it 'includes secrets in JSON when provided' do
        secrets = {
          flux_ssh_key_path: '/run/secrets/flux-ssh',
          sops_age_key_path: '/run/secrets/age'
        }
        result = described_class.generate(
          cluster_name: 'test',
          secrets: secrets
        )
        expect(result).to include('"secrets"')
        expect(result).to include('"flux_ssh_key_path"')
      end

      it 'excludes secrets when nil' do
        result = described_class.generate(cluster_name: 'test', secrets: nil)
        expect(result).not_to include('"secrets"')
      end

      it 'excludes secrets when empty hash' do
        result = described_class.generate(cluster_name: 'test', secrets: {})
        expect(result).not_to include('"secrets"')
      end
    end

    describe 'bootstrap_secrets passthrough' do
      it 'includes bootstrap_secrets in JSON when provided' do
        bs = { sops_age_key: 'AGE-SECRET-KEY-1...' }
        result = described_class.generate(
          cluster_name: 'test',
          bootstrap_secrets: bs
        )
        expect(result).to include('"bootstrap_secrets"')
        expect(result).to include('"sops_age_key"')
      end

      it 'excludes bootstrap_secrets when nil' do
        result = described_class.generate(cluster_name: 'test', bootstrap_secrets: nil)
        expect(result).not_to include('"bootstrap_secrets"')
      end

      it 'excludes bootstrap_secrets when empty' do
        result = described_class.generate(cluster_name: 'test', bootstrap_secrets: {})
        expect(result).not_to include('"bootstrap_secrets"')
      end
    end

    describe 'k3s config passthrough' do
      it 'includes k3s config when provided' do
        k3s = { disable: ['traefik', 'servicelb'], flannel_backend: 'none' }
        result = described_class.generate(
          cluster_name: 'test',
          k3s: k3s
        )
        expect(result).to include('"k3s"')
        expect(result).to include('"disable"')
        expect(result).to include('"flannel_backend"')
      end

      it 'excludes k3s key when nil' do
        result = described_class.generate(cluster_name: 'test', k3s: nil)
        json_str = result.lines.find { |l| l.strip.start_with?('{') }&.strip
        parsed = JSON.parse(json_str)
        expect(parsed).not_to have_key('k3s')
      end

      it 'excludes k3s key when empty' do
        result = described_class.generate(cluster_name: 'test', k3s: {})
        json_str = result.lines.find { |l| l.strip.start_with?('{') }&.strip
        parsed = JSON.parse(json_str)
        expect(parsed).not_to have_key('k3s')
      end
    end

    describe 'kubernetes config passthrough' do
      it 'includes kubernetes config when provided' do
        kubernetes = { version: '1.29.0', runtime: 'containerd' }
        result = described_class.generate(
          cluster_name: 'test',
          distribution: :kubernetes,
          kubernetes: kubernetes
        )
        expect(result).to include('"kubernetes"')
        expect(result).to include('"version"')
      end

      it 'excludes kubernetes when nil' do
        result = described_class.generate(cluster_name: 'test', kubernetes: nil)
        expect(result).not_to include('"kubernetes"')
      end
    end

    describe 'role normalization for kubernetes distribution' do
      it 'normalizes server to control-plane' do
        result = described_class.generate(
          cluster_name: 'test',
          distribution: :kubernetes,
          role: 'server'
        )
        expect(result).to include('"role":"control-plane"')
      end

      it 'normalizes agent to worker' do
        result = described_class.generate(
          cluster_name: 'test',
          distribution: :kubernetes,
          role: 'agent'
        )
        expect(result).to include('"role":"worker"')
      end

      it 'passes through unknown roles unchanged' do
        result = described_class.generate(
          cluster_name: 'test',
          distribution: :kubernetes,
          role: 'custom-role'
        )
        expect(result).to include('"role":"custom-role"')
      end
    end

    describe 'cloud_config format' do
      it 'writes config to correct path' do
        result = described_class.generate(
          cluster_name: 'test',
          format: :cloud_config
        )
        expect(result).to include('/etc/pangea/cluster-config.json')
      end

      it 'sets correct permissions' do
        result = described_class.generate(
          cluster_name: 'test',
          format: :cloud_config
        )
        expect(result).to include("'0640'")
      end

      it 'includes valid JSON in content' do
        result = described_class.generate(
          cluster_name: 'test',
          format: :cloud_config
        )
        json_match = result.match(/content: '(.+)'/)
        expect(json_match).not_to be_nil
        parsed = JSON.parse(json_match[1])
        expect(parsed['cluster_name']).to eq('test')
      end
    end

    describe 'join_server passthrough' do
      it 'includes join_server when provided' do
        result = described_class.generate(
          cluster_name: 'test',
          join_server: '10.0.0.1',
          role: 'agent',
          cluster_init: false
        )
        expect(result).to include('"join_server":"10.0.0.1"')
      end

      it 'excludes join_server when nil' do
        result = described_class.generate(cluster_name: 'test')
        expect(result).not_to include('"join_server"')
      end
    end

    describe 'network_id passthrough' do
      it 'includes network_id when provided' do
        result = described_class.generate(
          cluster_name: 'test',
          network_id: 'vpc-123'
        )
        expect(result).to include('"network_id":"vpc-123"')
      end

      it 'excludes network_id when nil' do
        result = described_class.generate(cluster_name: 'test')
        expect(result).not_to include('"network_id"')
      end
    end

    describe 'shell script format security' do
      it 'creates parent directory with mkdir -p' do
        result = described_class.generate(cluster_name: 'test')
        expect(result).to include('mkdir -p')
      end

      it 'sets restrictive permissions (0640)' do
        result = described_class.generate(cluster_name: 'test')
        expect(result).to include('chmod 0640')
      end

      it 'uses set -euo pipefail for safety' do
        result = described_class.generate(cluster_name: 'test')
        expect(result).to include('set -euo pipefail')
      end
    end
  end
end
