# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::ControlPlaneConfig do
  describe 'defaults' do
    subject { described_class.new({}) }

    it 'defaults api_server_extra_args to empty' do
      expect(subject.api_server_extra_args).to eq({})
    end

    it 'defaults disable_kube_proxy to false' do
      expect(subject.disable_kube_proxy).to be false
    end

    it 'defaults etcd_external to false' do
      expect(subject.etcd_external).to be false
    end

    it 'defaults etcd_endpoints to empty' do
      expect(subject.etcd_endpoints).to eq([])
    end
  end

  describe 'custom values' do
    subject do
      described_class.new(
        api_server_extra_args: { 'audit-log-path' => '/var/log/audit.log' },
        api_server_extra_sans: ['api.cluster.local'],
        controller_manager_extra_args: { 'node-cidr-mask-size' => '24' },
        scheduler_extra_args: { 'leader-elect' => 'true' },
        disable_kube_proxy: true,
        etcd_external: true,
        etcd_endpoints: ['https://etcd1:2379'],
        etcd_ca_file: '/etc/etcd/ca.pem'
      )
    end

    it 'accepts api_server_extra_args' do
      expect(subject.api_server_extra_args).to eq({ 'audit-log-path' => '/var/log/audit.log' })
    end

    it 'accepts disable_kube_proxy' do
      expect(subject.disable_kube_proxy).to be true
    end

    it 'accepts external etcd config' do
      expect(subject.etcd_external).to be true
      expect(subject.etcd_endpoints).to eq(['https://etcd1:2379'])
      expect(subject.etcd_ca_file).to eq('/etc/etcd/ca.pem')
    end
  end

  describe '#to_h' do
    it 'omits empty collections and false booleans by default' do
      hash = described_class.new({}).to_h
      expect(hash).to eq({})
    end

    it 'includes non-empty fields' do
      config = described_class.new(
        api_server_extra_args: { 'v' => '2' },
        disable_kube_proxy: true
      )
      hash = config.to_h
      expect(hash[:api_server_extra_args]).to eq({ 'v' => '2' })
      expect(hash[:disable_kube_proxy]).to be true
    end

    it 'includes external etcd fields' do
      config = described_class.new(
        etcd_external: true,
        etcd_endpoints: ['https://etcd:2379'],
        etcd_ca_file: '/ca.pem',
        etcd_cert_file: '/cert.pem',
        etcd_key_file: '/key.pem'
      )
      hash = config.to_h
      expect(hash[:etcd_external]).to be true
      expect(hash[:etcd_ca_file]).to eq('/ca.pem')
    end
  end
end
