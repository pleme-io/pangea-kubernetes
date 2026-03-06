# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::K3sConfig do
  describe 'defaults' do
    subject { described_class.new({}) }

    it 'defaults cluster_cidr to nil' do
      expect(subject.cluster_cidr).to be_nil
    end

    it 'defaults service_cidr to nil' do
      expect(subject.service_cidr).to be_nil
    end

    it 'defaults disable to empty' do
      expect(subject.disable).to eq([])
    end

    it 'defaults disable_agent to false' do
      expect(subject.disable_agent).to be false
    end

    it 'defaults nvidia_enable to false' do
      expect(subject.nvidia_enable).to be false
    end

    it 'defaults graceful_node_shutdown to true' do
      expect(subject.graceful_node_shutdown).to be true
    end

    it 'defaults firewall to nil' do
      expect(subject.firewall).to be_nil
    end

    it 'defaults kernel to nil' do
      expect(subject.kernel).to be_nil
    end

    it 'defaults wait_for_dns to nil' do
      expect(subject.wait_for_dns).to be_nil
    end
  end

  describe 'full configuration' do
    subject do
      described_class.new(
        cluster_cidr: '10.42.0.0/16',
        service_cidr: '10.43.0.0/16',
        cluster_dns: '10.43.0.10',
        node_name: 'cp-0',
        node_labels: { 'role' => 'control-plane' },
        node_taints: ['node-role.kubernetes.io/master:NoSchedule'],
        node_ip: '10.0.0.10',
        extra_flags: ['--disable=traefik', '--disable=servicelb'],
        data_dir: '/var/lib/rancher/k3s',
        disable: %w[traefik servicelb],
        disable_agent: true,
        extra_kubelet_config: { 'max-pods' => '150' },
        manifests: { 'coredns.yaml' => 'apiVersion: v1...' },
        firewall: { enabled: true, extra_tcp_ports: [8080] },
        kernel: { extra_modules: ['br_netfilter'] },
        wait_for_dns: { enabled: true, hostname: 'api.local' },
        nvidia_enable: true,
        graceful_node_shutdown: false
      )
    end

    it 'stores networking config' do
      expect(subject.cluster_cidr).to eq('10.42.0.0/16')
      expect(subject.service_cidr).to eq('10.43.0.0/16')
      expect(subject.cluster_dns).to eq('10.43.0.10')
    end

    it 'stores node config' do
      expect(subject.node_name).to eq('cp-0')
      expect(subject.node_labels).to eq({ 'role' => 'control-plane' })
      expect(subject.node_taints).to eq(['node-role.kubernetes.io/master:NoSchedule'])
    end

    it 'stores disable list' do
      expect(subject.disable).to eq(%w[traefik servicelb])
      expect(subject.disable_agent).to be true
    end

    it 'stores nested configs' do
      expect(subject.firewall).to be_a(Pangea::Kubernetes::Types::FirewallConfig)
      expect(subject.firewall.extra_tcp_ports).to eq([8080])
      expect(subject.kernel.extra_modules).to eq(['br_netfilter'])
      expect(subject.wait_for_dns.hostname).to eq('api.local')
    end

    it 'stores gpu and shutdown config' do
      expect(subject.nvidia_enable).to be true
      expect(subject.graceful_node_shutdown).to be false
    end
  end

  describe '#to_h' do
    it 'omits nil and empty fields' do
      hash = described_class.new({}).to_h
      expect(hash).not_to have_key(:cluster_cidr)
      expect(hash).not_to have_key(:node_labels)
      expect(hash).not_to have_key(:disable)
      expect(hash).not_to have_key(:firewall)
      expect(hash).to have_key(:graceful_node_shutdown)
    end

    it 'includes nested config to_h' do
      config = described_class.new(
        cluster_cidr: '10.42.0.0/16',
        firewall: { enabled: true, extra_tcp_ports: [9090] },
        disable: %w[traefik]
      )
      hash = config.to_h
      expect(hash[:cluster_cidr]).to eq('10.42.0.0/16')
      expect(hash[:firewall][:extra_tcp_ports]).to eq([9090])
      expect(hash[:disable]).to eq(%w[traefik])
    end

    it 'omits disable_agent when false' do
      hash = described_class.new({}).to_h
      expect(hash).not_to have_key(:disable_agent)
    end

    it 'includes disable_agent when true' do
      hash = described_class.new(disable_agent: true).to_h
      expect(hash[:disable_agent]).to be true
    end

    it 'omits nvidia_enable when false' do
      hash = described_class.new({}).to_h
      expect(hash).not_to have_key(:nvidia_enable)
    end
  end
end
