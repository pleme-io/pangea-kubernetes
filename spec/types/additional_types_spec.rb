# frozen_string_literal: true

RSpec.describe 'Additional Type Specs' do
  describe Pangea::Kubernetes::Types::AddonConfig do
    it 'creates with minimal attributes' do
      addon = described_class.new(name: :ingress)
      expect(addon.name).to eq(:ingress)
      expect(addon.enabled).to be true
    end

    it 'defaults enabled to true' do
      addon = described_class.new(name: :monitoring)
      expect(addon.enabled).to be true
    end

    it 'defaults version to nil' do
      addon = described_class.new(name: :monitoring)
      expect(addon.version).to be_nil
    end

    it 'defaults config to empty hash' do
      addon = described_class.new(name: :monitoring)
      expect(addon.config).to eq({})
    end

    it 'accepts all attributes' do
      addon = described_class.new(
        name: :ingress,
        enabled: false,
        version: '1.5.0',
        config: { replicas: 3 }
      )
      expect(addon.name).to eq(:ingress)
      expect(addon.enabled).to be false
      expect(addon.version).to eq('1.5.0')
      expect(addon.config).to eq({ replicas: 3 })
    end

    describe '#to_h' do
      it 'serializes basic fields' do
        addon = described_class.new(name: :ingress)
        hash = addon.to_h
        expect(hash[:name]).to eq(:ingress)
        expect(hash[:enabled]).to be true
      end

      it 'includes version when set' do
        addon = described_class.new(name: :ingress, version: '2.0.0')
        hash = addon.to_h
        expect(hash[:version]).to eq('2.0.0')
      end

      it 'omits version when nil' do
        addon = described_class.new(name: :ingress)
        hash = addon.to_h
        expect(hash).not_to have_key(:version)
      end

      it 'includes config when non-empty' do
        addon = described_class.new(name: :ingress, config: { replicas: 2 })
        hash = addon.to_h
        expect(hash[:config]).to eq({ replicas: 2 })
      end

      it 'omits config when empty' do
        addon = described_class.new(name: :ingress)
        hash = addon.to_h
        expect(hash).not_to have_key(:config)
      end
    end
  end

  describe Pangea::Kubernetes::Types::NetworkConfig do
    it 'creates with defaults' do
      network = described_class.new({})
      expect(network.vpc_cidr).to be_nil
      expect(network.pod_cidr).to be_nil
      expect(network.service_cidr).to be_nil
      expect(network.subnet_ids).to eq([])
      expect(network.security_group_ids).to eq([])
      expect(network.private_endpoint).to be true
      expect(network.public_endpoint).to be false
    end

    it 'accepts all attributes' do
      network = described_class.new(
        vpc_cidr: '10.0.0.0/16',
        pod_cidr: '10.1.0.0/16',
        service_cidr: '10.2.0.0/20',
        subnet_ids: ['subnet-1', 'subnet-2'],
        security_group_ids: ['sg-123'],
        private_endpoint: false,
        public_endpoint: true
      )
      expect(network.vpc_cidr).to eq('10.0.0.0/16')
      expect(network.pod_cidr).to eq('10.1.0.0/16')
      expect(network.service_cidr).to eq('10.2.0.0/20')
      expect(network.subnet_ids).to eq(['subnet-1', 'subnet-2'])
      expect(network.security_group_ids).to eq(['sg-123'])
      expect(network.private_endpoint).to be false
      expect(network.public_endpoint).to be true
    end

    describe '#to_h' do
      it 'always includes endpoint settings' do
        network = described_class.new({})
        hash = network.to_h
        expect(hash[:private_endpoint]).to be true
        expect(hash[:public_endpoint]).to be false
      end

      it 'includes vpc_cidr when set' do
        network = described_class.new(vpc_cidr: '10.0.0.0/16')
        hash = network.to_h
        expect(hash[:vpc_cidr]).to eq('10.0.0.0/16')
      end

      it 'omits vpc_cidr when nil' do
        network = described_class.new({})
        hash = network.to_h
        expect(hash).not_to have_key(:vpc_cidr)
      end

      it 'includes pod_cidr when set' do
        network = described_class.new(pod_cidr: '10.1.0.0/16')
        hash = network.to_h
        expect(hash[:pod_cidr]).to eq('10.1.0.0/16')
      end

      it 'omits pod_cidr when nil' do
        network = described_class.new({})
        hash = network.to_h
        expect(hash).not_to have_key(:pod_cidr)
      end

      it 'includes service_cidr when set' do
        network = described_class.new(service_cidr: '10.2.0.0/20')
        hash = network.to_h
        expect(hash[:service_cidr]).to eq('10.2.0.0/20')
      end

      it 'omits service_cidr when nil' do
        network = described_class.new({})
        hash = network.to_h
        expect(hash).not_to have_key(:service_cidr)
      end

      it 'includes subnet_ids when non-empty' do
        network = described_class.new(subnet_ids: ['subnet-a'])
        hash = network.to_h
        expect(hash[:subnet_ids]).to eq(['subnet-a'])
      end

      it 'omits subnet_ids when empty' do
        network = described_class.new({})
        hash = network.to_h
        expect(hash).not_to have_key(:subnet_ids)
      end

      it 'includes security_group_ids when non-empty' do
        network = described_class.new(security_group_ids: ['sg-1'])
        hash = network.to_h
        expect(hash[:security_group_ids]).to eq(['sg-1'])
      end

      it 'omits security_group_ids when empty' do
        network = described_class.new({})
        hash = network.to_h
        expect(hash).not_to have_key(:security_group_ids)
      end
    end
  end

  describe Pangea::Kubernetes::Types::FluxCDConfig do
    it 'creates with minimal attributes' do
      flux = described_class.new(source_url: 'ssh://git@github.com/org/k8s.git')
      expect(flux.source_url).to eq('ssh://git@github.com/org/k8s.git')
    end

    it 'defaults enabled to true' do
      flux = described_class.new(source_url: 'ssh://git@github.com/org/k8s.git')
      expect(flux.enabled).to be true
    end

    it 'defaults source_auth to ssh' do
      flux = described_class.new(source_url: 'ssh://git@github.com/org/k8s.git')
      expect(flux.source_auth).to eq('ssh')
    end

    it 'defaults source_interval to 1m0s' do
      flux = described_class.new(source_url: 'ssh://git@github.com/org/k8s.git')
      expect(flux.source_interval).to eq('1m0s')
    end

    it 'defaults reconcile_path to ./' do
      flux = described_class.new(source_url: 'ssh://git@github.com/org/k8s.git')
      expect(flux.reconcile_path).to eq('./')
    end

    it 'defaults reconcile_interval to 2m0s' do
      flux = described_class.new(source_url: 'ssh://git@github.com/org/k8s.git')
      expect(flux.reconcile_interval).to eq('2m0s')
    end

    it 'defaults sops_enabled to true' do
      flux = described_class.new(source_url: 'ssh://git@github.com/org/k8s.git')
      expect(flux.sops_enabled).to be true
    end

    it 'accepts token source_auth' do
      flux = described_class.new(source_url: 'https://github.com/org/k8s.git', source_auth: 'token')
      expect(flux.source_auth).to eq('token')
    end

    it 'rejects invalid source_auth' do
      expect {
        described_class.new(source_url: 'ssh://git@github.com/org/k8s.git', source_auth: 'oauth')
      }.to raise_error(Dry::Struct::Error)
    end

    describe '#to_h' do
      it 'serializes all fields' do
        flux = described_class.new(
          source_url: 'ssh://git@github.com/org/k8s.git',
          source_auth: 'ssh',
          source_interval: '5m0s',
          reconcile_path: 'clusters/prod',
          reconcile_interval: '10m0s',
          sops_enabled: false
        )
        hash = flux.to_h
        expect(hash[:enabled]).to be true
        expect(hash[:source_url]).to eq('ssh://git@github.com/org/k8s.git')
        expect(hash[:source_auth]).to eq('ssh')
        expect(hash[:source_interval]).to eq('5m0s')
        expect(hash[:reconcile_path]).to eq('clusters/prod')
        expect(hash[:reconcile_interval]).to eq('10m0s')
        expect(hash[:sops_enabled]).to be false
      end
    end
  end

  describe Pangea::Kubernetes::Types::NixOSConfig do
    it 'creates with defaults' do
      nixos = described_class.new({})
      expect(nixos.image_id).to be_nil
      expect(nixos.flake_url).to be_nil
      expect(nixos.extra_modules).to eq([])
      expect(nixos.sops_age_key_secret).to be_nil
      expect(nixos.flux_ssh_key_secret).to be_nil
    end

    it 'accepts all attributes' do
      nixos = described_class.new(
        image_id: 'nixos-24-05',
        flake_url: 'github:pleme-io/blackmatter-kubernetes',
        extra_modules: ['monitoring', 'logging'],
        sops_age_key_secret: 'sops-key',
        flux_ssh_key_secret: 'flux-key'
      )
      expect(nixos.image_id).to eq('nixos-24-05')
      expect(nixos.flake_url).to eq('github:pleme-io/blackmatter-kubernetes')
      expect(nixos.extra_modules).to eq(['monitoring', 'logging'])
      expect(nixos.sops_age_key_secret).to eq('sops-key')
      expect(nixos.flux_ssh_key_secret).to eq('flux-key')
    end

    describe '#to_h' do
      it 'returns empty hash when all defaults' do
        nixos = described_class.new({})
        hash = nixos.to_h
        expect(hash).to eq({})
      end

      it 'includes image_id when set' do
        nixos = described_class.new(image_id: 'nixos-24-05')
        hash = nixos.to_h
        expect(hash[:image_id]).to eq('nixos-24-05')
      end

      it 'includes flake_url when set' do
        nixos = described_class.new(flake_url: 'github:org/repo')
        hash = nixos.to_h
        expect(hash[:flake_url]).to eq('github:org/repo')
      end

      it 'includes extra_modules when non-empty' do
        nixos = described_class.new(extra_modules: ['mod1'])
        hash = nixos.to_h
        expect(hash[:extra_modules]).to eq(['mod1'])
      end

      it 'omits extra_modules when empty' do
        nixos = described_class.new({})
        hash = nixos.to_h
        expect(hash).not_to have_key(:extra_modules)
      end

      it 'includes sops_age_key_secret when set' do
        nixos = described_class.new(sops_age_key_secret: 'key')
        hash = nixos.to_h
        expect(hash[:sops_age_key_secret]).to eq('key')
      end

      it 'includes flux_ssh_key_secret when set' do
        nixos = described_class.new(flux_ssh_key_secret: 'key')
        hash = nixos.to_h
        expect(hash[:flux_ssh_key_secret]).to eq('key')
      end
    end
  end

  describe Pangea::Kubernetes::Types::DeploymentContext do
    it 'creates with required attributes' do
      ctx = described_class.new(environment: :production, cluster_name: :prod)
      expect(ctx.environment).to eq(:production)
      expect(ctx.cluster_name).to eq(:prod)
    end

    it 'accepts all environment values' do
      %i[production staging development].each do |env|
        ctx = described_class.new(environment: env, cluster_name: :test)
        expect(ctx.environment).to eq(env)
      end
    end

    it 'rejects invalid environment' do
      expect {
        described_class.new(environment: :sandbox, cluster_name: :test)
      }.to raise_error(Dry::Struct::Error)
    end

    it 'defaults team to nil' do
      ctx = described_class.new(environment: :production, cluster_name: :prod)
      expect(ctx.team).to be_nil
    end

    it 'defaults cost_center to nil' do
      ctx = described_class.new(environment: :production, cluster_name: :prod)
      expect(ctx.cost_center).to be_nil
    end

    it 'accepts optional team' do
      ctx = described_class.new(environment: :production, cluster_name: :prod, team: 'platform')
      expect(ctx.team).to eq('platform')
    end

    it 'accepts optional cost_center' do
      ctx = described_class.new(environment: :production, cluster_name: :prod, cost_center: 'CC-123')
      expect(ctx.cost_center).to eq('CC-123')
    end

    describe '#to_h' do
      it 'serializes required fields' do
        ctx = described_class.new(environment: :production, cluster_name: :prod)
        hash = ctx.to_h
        expect(hash[:environment]).to eq(:production)
        expect(hash[:cluster_name]).to eq(:prod)
      end

      it 'includes team when set' do
        ctx = described_class.new(environment: :production, cluster_name: :prod, team: 'infra')
        hash = ctx.to_h
        expect(hash[:team]).to eq('infra')
      end

      it 'omits team when nil' do
        ctx = described_class.new(environment: :production, cluster_name: :prod)
        hash = ctx.to_h
        expect(hash).not_to have_key(:team)
      end

      it 'includes cost_center when set' do
        ctx = described_class.new(environment: :production, cluster_name: :prod, cost_center: 'CC-456')
        hash = ctx.to_h
        expect(hash[:cost_center]).to eq('CC-456')
      end

      it 'omits cost_center when nil' do
        ctx = described_class.new(environment: :production, cluster_name: :prod)
        hash = ctx.to_h
        expect(hash).not_to have_key(:cost_center)
      end
    end
  end

  describe Pangea::Kubernetes::Types::LoadBalancerConfig do
    let(:minimal_attrs) do
      {
        instance_type: 'cx21',
        region: 'nbg1',
        backends: [{ name: 'node-1', address: '10.0.0.1', port: 30080 }]
      }
    end

    it 'creates with minimal attributes' do
      lb = described_class.new(minimal_attrs)
      expect(lb.instance_type).to eq('cx21')
      expect(lb.region).to eq('nbg1')
    end

    it 'defaults mode to haproxy' do
      lb = described_class.new(minimal_attrs)
      expect(lb.mode).to eq('haproxy')
    end

    it 'defaults instance_count to 2' do
      lb = described_class.new(minimal_attrs)
      expect(lb.instance_count).to eq(2)
    end

    it 'defaults health_check_interval to 5s' do
      lb = described_class.new(minimal_attrs)
      expect(lb.health_check_interval).to eq('5s')
    end

    it 'defaults max_connections to 50000' do
      lb = described_class.new(minimal_attrs)
      expect(lb.max_connections).to eq(50_000)
    end

    it 'defaults frontend_ports to [80, 443]' do
      lb = described_class.new(minimal_attrs)
      expect(lb.frontend_ports).to eq([80, 443])
    end

    it 'defaults tags to empty hash' do
      lb = described_class.new(minimal_attrs)
      expect(lb.tags).to eq({})
    end

    it 'defaults BGP fields to nil' do
      lb = described_class.new(minimal_attrs)
      expect(lb.bgp_asn).to be_nil
      expect(lb.bgp_neighbor).to be_nil
      expect(lb.vrrp_interface).to be_nil
      expect(lb.virtual_ips).to eq([])
    end

    it 'accepts haproxy-bird mode' do
      lb = described_class.new(minimal_attrs.merge(mode: 'haproxy-bird'))
      expect(lb.mode).to eq('haproxy-bird')
    end

    it 'rejects invalid mode' do
      expect {
        described_class.new(minimal_attrs.merge(mode: 'nginx'))
      }.to raise_error(Dry::Struct::Error)
    end

    it 'rejects instance_count < 1' do
      expect {
        described_class.new(minimal_attrs.merge(instance_count: 0))
      }.to raise_error(Dry::Struct::Error)
    end

    it 'requires at least one backend' do
      expect {
        described_class.new(minimal_attrs.merge(backends: []))
      }.to raise_error(Dry::Struct::Error)
    end

    describe '#bare_metal?' do
      it 'returns false for haproxy mode' do
        lb = described_class.new(minimal_attrs)
        expect(lb.bare_metal?).to be false
      end

      it 'returns true for haproxy-bird mode' do
        lb = described_class.new(minimal_attrs.merge(mode: 'haproxy-bird'))
        expect(lb.bare_metal?).to be true
      end
    end

    describe '#to_h' do
      it 'serializes required fields' do
        lb = described_class.new(minimal_attrs)
        hash = lb.to_h
        expect(hash[:mode]).to eq('haproxy')
        expect(hash[:instance_count]).to eq(2)
        expect(hash[:instance_type]).to eq('cx21')
        expect(hash[:region]).to eq('nbg1')
        expect(hash[:backends].size).to eq(1)
        expect(hash[:health_check_interval]).to eq('5s')
        expect(hash[:max_connections]).to eq(50_000)
        expect(hash[:frontend_ports]).to eq([80, 443])
      end

      it 'includes tags when non-empty' do
        lb = described_class.new(minimal_attrs.merge(tags: { Env: 'prod' }))
        hash = lb.to_h
        expect(hash[:tags]).to eq({ Env: 'prod' })
      end

      it 'omits tags when empty' do
        lb = described_class.new(minimal_attrs)
        hash = lb.to_h
        expect(hash).not_to have_key(:tags)
      end

      it 'includes BGP fields when set' do
        lb = described_class.new(minimal_attrs.merge(
          mode: 'haproxy-bird',
          bgp_asn: 65000,
          bgp_neighbor: '10.0.0.254',
          vrrp_interface: 'eth0',
          virtual_ips: ['10.0.0.100']
        ))
        hash = lb.to_h
        expect(hash[:bgp_asn]).to eq(65000)
        expect(hash[:bgp_neighbor]).to eq('10.0.0.254')
        expect(hash[:vrrp_interface]).to eq('eth0')
        expect(hash[:virtual_ips]).to eq(['10.0.0.100'])
      end

      it 'omits BGP fields when nil/empty' do
        lb = described_class.new(minimal_attrs)
        hash = lb.to_h
        expect(hash).not_to have_key(:bgp_asn)
        expect(hash).not_to have_key(:bgp_neighbor)
        expect(hash).not_to have_key(:vrrp_interface)
        expect(hash).not_to have_key(:virtual_ips)
      end
    end
  end
end
