# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::BareMetal::CloudInit do
  describe '.generate' do
    let(:base_params) do
      {
        cluster_name: 'production',
        distribution: :k3s,
        profile: 'cilium-standard',
        distribution_track: '1.34',
        role: 'server',
        node_index: 0,
        cluster_init: true
      }
    end

    it 'generates valid cloud-init YAML' do
      result = described_class.generate(**base_params)
      expect(result).to start_with('#cloud-config')
      expect(result).to include('write_files:')
      expect(result).to include('/etc/pangea/cluster-config.json')
    end

    it 'includes cluster_name in config' do
      result = described_class.generate(**base_params)
      expect(result).to include('"cluster_name":"production"')
    end

    it 'includes distribution' do
      result = described_class.generate(**base_params)
      expect(result).to include('"distribution":"k3s"')
    end

    it 'includes profile' do
      result = described_class.generate(**base_params)
      expect(result).to include('"profile":"cilium-standard"')
    end

    it 'includes distribution_track' do
      result = described_class.generate(**base_params)
      expect(result).to include('"distribution_track":"1.34"')
    end

    it 'includes role' do
      result = described_class.generate(**base_params)
      expect(result).to include('"role":"server"')
    end

    it 'includes cluster_init flag' do
      result = described_class.generate(**base_params)
      expect(result).to include('"cluster_init":true')
    end

    it 'sets cluster_init to false for non-init nodes' do
      result = described_class.generate(**base_params.merge(cluster_init: false, node_index: 1))
      expect(result).to include('"cluster_init":false')
    end

    it 'includes network_id when provided' do
      result = described_class.generate(**base_params.merge(network_id: '12345'))
      expect(result).to include('"network_id":"12345"')
    end

    it 'excludes network_id when not provided' do
      result = described_class.generate(**base_params)
      expect(result).not_to include('network_id')
    end

    it 'includes join_server for agent nodes' do
      result = described_class.generate(
        cluster_name: 'production',
        distribution: :k3s,
        profile: 'cilium-standard',
        distribution_track: '1.34',
        role: 'agent',
        node_index: 0,
        cluster_init: false,
        join_server: '10.0.0.1'
      )
      expect(result).to include('"join_server":"10.0.0.1"')
    end

    it 'starts pangea-k3s-bootstrap service for k3s' do
      result = described_class.generate(**base_params)
      expect(result).to include('pangea-k3s-bootstrap')
    end

    context 'with vanilla kubernetes distribution' do
      let(:k8s_params) { base_params.merge(distribution: :kubernetes, profile: 'calico-standard') }

      it 'includes kubernetes distribution' do
        result = described_class.generate(**k8s_params)
        expect(result).to include('"distribution":"kubernetes"')
      end

      it 'normalizes server role to control-plane' do
        result = described_class.generate(**k8s_params.merge(role: 'server'))
        expect(result).to include('"role":"control-plane"')
      end

      it 'normalizes agent role to worker' do
        result = described_class.generate(**k8s_params.merge(role: 'agent', cluster_init: false))
        expect(result).to include('"role":"worker"')
      end

      it 'starts pangea-k8s-bootstrap service' do
        result = described_class.generate(**k8s_params)
        expect(result).to include('pangea-k8s-bootstrap')
      end
    end

    context 'with fluxcd config' do
      it 'includes fluxcd configuration' do
        fluxcd = { enabled: true, source_url: 'ssh://git@github.com/pleme-io/k8s.git' }
        result = described_class.generate(**base_params.merge(fluxcd: fluxcd))
        expect(result).to include('"fluxcd"')
        expect(result).to include('pleme-io/k8s.git')
      end
    end
  end
end
