# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::VanillaKubernetesConfig do
  describe 'defaults' do
    subject { described_class.new({}) }

    it 'defaults shared fields same as K3sConfig' do
      expect(subject.cluster_cidr).to be_nil
      expect(subject.disable).to eq([])
      expect(subject.graceful_node_shutdown).to be true
    end

    it 'defaults control_plane to nil' do
      expect(subject.control_plane).to be_nil
    end

    it 'defaults pki to nil' do
      expect(subject.pki).to be_nil
    end

    it 'defaults etcd to nil' do
      expect(subject.etcd).to be_nil
    end
  end

  describe 'full configuration with control plane' do
    subject do
      described_class.new(
        cluster_cidr: '10.244.0.0/16',
        service_cidr: '10.96.0.0/12',
        cluster_dns: '10.96.0.10',
        firewall: { enabled: true },
        kernel: { extra_modules: ['br_netfilter'], hardening: true },
        control_plane: {
          api_server_extra_args: { 'audit-log-path' => '/var/log/audit.log' },
          api_server_extra_sans: ['api.example.com'],
          disable_kube_proxy: true,
          etcd_external: true,
          etcd_endpoints: ['https://etcd1:2379']
        },
        pki: {
          mode: 'manual',
          ca_cert_path: '/pki/ca.pem',
          api_server_extra_sans: ['10.0.0.1']
        },
        etcd: {
          initial_cluster_state: 'existing',
          external_endpoints: ['https://etcd1:2379']
        }
      )
    end

    it 'stores control plane config' do
      expect(subject.control_plane).to be_a(Pangea::Kubernetes::Types::ControlPlaneConfig)
      expect(subject.control_plane.disable_kube_proxy).to be true
      expect(subject.control_plane.api_server_extra_sans).to eq(['api.example.com'])
    end

    it 'stores PKI config' do
      expect(subject.pki).to be_a(Pangea::Kubernetes::Types::PKIConfig)
      expect(subject.pki.mode).to eq('manual')
    end

    it 'stores etcd config' do
      expect(subject.etcd).to be_a(Pangea::Kubernetes::Types::EtcdConfig)
      expect(subject.etcd.initial_cluster_state).to eq('existing')
      expect(subject.etcd.external?).to be true
    end

    it 'stores shared fields' do
      expect(subject.cluster_cidr).to eq('10.244.0.0/16')
      expect(subject.firewall.enabled).to be true
    end
  end

  describe '#to_h' do
    it 'omits nil nested configs' do
      hash = described_class.new({}).to_h
      expect(hash).not_to have_key(:control_plane)
      expect(hash).not_to have_key(:pki)
      expect(hash).not_to have_key(:etcd)
    end

    it 'includes nested config hashes' do
      config = described_class.new(
        control_plane: { disable_kube_proxy: true },
        pki: { mode: 'auto' },
        etcd: { data_dir: '/data/etcd' }
      )
      hash = config.to_h
      expect(hash[:control_plane][:disable_kube_proxy]).to be true
      expect(hash[:pki][:mode]).to eq('auto')
      expect(hash[:etcd][:data_dir]).to eq('/data/etcd')
    end

    it 'includes shared fields alongside k8s-specific ones' do
      config = described_class.new(
        cluster_cidr: '10.244.0.0/16',
        control_plane: { api_server_extra_args: { 'v' => '2' } }
      )
      hash = config.to_h
      expect(hash[:cluster_cidr]).to eq('10.244.0.0/16')
      expect(hash[:control_plane][:api_server_extra_args]).to eq({ 'v' => '2' })
    end
  end
end
