# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::ClusterConfig do
  let(:minimal_attrs) do
    {
      backend: :aws,
      region: 'us-east-1',
      node_pools: [
        { name: :system, instance_types: ['t3.large'], min_size: 2, max_size: 5 }
      ]
    }
  end

  describe 'creation' do
    it 'creates with minimal attributes' do
      config = described_class.new(minimal_attrs)
      expect(config.backend).to eq(:aws)
      expect(config.region).to eq('us-east-1')
      expect(config.kubernetes_version).to eq('1.29')
      expect(config.node_pools.size).to eq(1)
    end

    it 'accepts all supported backends' do
      %i[aws gcp azure hcloud aws_nixos gcp_nixos azure_nixos].each do |backend|
        config = described_class.new(minimal_attrs.merge(backend: backend))
        expect(config.backend).to eq(backend)
      end
    end

    it 'rejects unsupported backends' do
      expect {
        described_class.new(minimal_attrs.merge(backend: :digitalocean))
      }.to raise_error(Dry::Struct::Error)
    end

    it 'accepts valid kubernetes versions' do
      %w[1.27 1.28 1.29 1.30 1.31 1.32 1.33 1.34].each do |version|
        config = described_class.new(minimal_attrs.merge(kubernetes_version: version))
        expect(config.kubernetes_version).to eq(version)
      end
    end

    it 'rejects invalid kubernetes versions' do
      expect {
        described_class.new(minimal_attrs.merge(kubernetes_version: '1.26'))
      }.to raise_error(Dry::Struct::Error)
    end

    it 'requires at least one node pool' do
      expect {
        described_class.new(minimal_attrs.merge(node_pools: []))
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'defaults' do
    it 'defaults kubernetes_version to 1.29' do
      config = described_class.new(minimal_attrs)
      expect(config.kubernetes_version).to eq('1.29')
    end

    it 'defaults encryption_at_rest to true' do
      config = described_class.new(minimal_attrs)
      expect(config.encryption_at_rest).to be true
    end

    it 'defaults tags to empty hash' do
      config = described_class.new(minimal_attrs)
      expect(config.tags).to eq({})
    end

    it 'defaults addons to empty array' do
      config = described_class.new(minimal_attrs)
      expect(config.addons).to eq([])
    end

    it 'defaults distribution to k3s' do
      config = described_class.new(minimal_attrs)
      expect(config.distribution).to eq(:k3s)
    end

    it 'defaults profile to cloud-server' do
      config = described_class.new(minimal_attrs)
      expect(config.profile).to eq('cloud-server')
    end
  end

  describe '#managed_kubernetes?' do
    it 'returns true for managed backends (aws, gcp, azure)' do
      %i[aws gcp azure].each do |backend|
        config = described_class.new(minimal_attrs.merge(backend: backend))
        expect(config.managed_kubernetes?).to be true
      end
    end

    it 'returns false for NixOS backends' do
      %i[hcloud aws_nixos gcp_nixos azure_nixos].each do |backend|
        config = described_class.new(minimal_attrs.merge(backend: backend))
        expect(config.managed_kubernetes?).to be false
      end
    end
  end

  describe '#nixos_backend?' do
    it 'returns true for NixOS backends' do
      %i[hcloud aws_nixos gcp_nixos azure_nixos].each do |backend|
        config = described_class.new(minimal_attrs.merge(backend: backend))
        expect(config.nixos_backend?).to be true
      end
    end

    it 'returns false for managed backends' do
      %i[aws gcp azure].each do |backend|
        config = described_class.new(minimal_attrs.merge(backend: backend))
        expect(config.nixos_backend?).to be false
      end
    end
  end

  describe 'distribution and profile' do
    it 'accepts k3s distribution' do
      config = described_class.new(minimal_attrs.merge(distribution: :k3s))
      expect(config.distribution).to eq(:k3s)
    end

    it 'accepts kubernetes distribution' do
      config = described_class.new(minimal_attrs.merge(distribution: :kubernetes))
      expect(config.distribution).to eq(:kubernetes)
    end

    it 'rejects unsupported distribution' do
      expect {
        described_class.new(minimal_attrs.merge(distribution: :microk8s))
      }.to raise_error(Dry::Struct::Error)
    end

    it 'accepts all supported profiles' do
      %w[flannel-minimal flannel-standard flannel-production
         calico-standard calico-hardened cilium-standard cilium-mesh istio-mesh].each do |profile|
        config = described_class.new(minimal_attrs.merge(profile: profile))
        expect(config.profile).to eq(profile)
      end
    end

    it 'rejects unsupported profile' do
      expect {
        described_class.new(minimal_attrs.merge(profile: 'invalid-profile'))
      }.to raise_error(Dry::Struct::Error)
    end

    it 'accepts distribution_track' do
      config = described_class.new(minimal_attrs.merge(distribution_track: '1.34'))
      expect(config.distribution_track).to eq('1.34')
    end
  end

  describe '#system_node_pool' do
    it 'returns the node pool named :system' do
      config = described_class.new(minimal_attrs.merge(
        node_pools: [
          { name: :workers, instance_types: ['c5.xlarge'] },
          { name: :system, instance_types: ['t3.large'] }
        ]
      ))
      expect(config.system_node_pool.name).to eq(:system)
    end

    it 'falls back to first node pool if no :system pool' do
      config = described_class.new(minimal_attrs.merge(
        node_pools: [
          { name: :workers, instance_types: ['c5.xlarge'] }
        ]
      ))
      expect(config.system_node_pool.name).to eq(:workers)
    end
  end

  describe '#worker_node_pools' do
    it 'returns all non-system node pools' do
      config = described_class.new(minimal_attrs.merge(
        node_pools: [
          { name: :system, instance_types: ['t3.large'] },
          { name: :workers, instance_types: ['c5.xlarge'] },
          { name: :gpu, instance_types: ['p3.2xlarge'] }
        ]
      ))
      workers = config.worker_node_pools
      expect(workers.size).to eq(2)
      expect(workers.map(&:name)).to contain_exactly(:workers, :gpu)
    end
  end

  describe 'provider-specific attributes' do
    it 'accepts AWS role_arn' do
      config = described_class.new(minimal_attrs.merge(role_arn: 'arn:aws:iam::123456789012:role/eks'))
      expect(config.role_arn).to eq('arn:aws:iam::123456789012:role/eks')
    end

    it 'accepts AWS ami_id and key_pair for NixOS backend' do
      config = described_class.new(minimal_attrs.merge(
        backend: :aws_nixos, ami_id: 'ami-nixos-test', key_pair: 'my-key'
      ))
      expect(config.ami_id).to eq('ami-nixos-test')
      expect(config.key_pair).to eq('my-key')
    end

    it 'accepts GCP project' do
      config = described_class.new(minimal_attrs.merge(backend: :gcp, project: 'my-project'))
      expect(config.project).to eq('my-project')
    end

    it 'accepts GCP gce_image for NixOS backend' do
      config = described_class.new(minimal_attrs.merge(
        backend: :gcp_nixos, project: 'my-project', gce_image: 'nixos-24-05'
      ))
      expect(config.gce_image).to eq('nixos-24-05')
    end

    it 'accepts Azure resource_group_name and dns_prefix' do
      config = described_class.new(minimal_attrs.merge(
        backend: :azure,
        resource_group_name: 'my-rg',
        dns_prefix: 'myaks'
      ))
      expect(config.resource_group_name).to eq('my-rg')
      expect(config.dns_prefix).to eq('myaks')
    end

    it 'accepts Azure azure_image_id for NixOS backend' do
      config = described_class.new(minimal_attrs.merge(
        backend: :azure_nixos,
        azure_image_id: '/subscriptions/.../images/nixos-24-05'
      ))
      expect(config.azure_image_id).to eq('/subscriptions/.../images/nixos-24-05')
    end
  end

  describe 'FluxCD configuration' do
    it 'accepts fluxcd config' do
      config = described_class.new(minimal_attrs.merge(
        fluxcd: {
          source_url: 'ssh://git@github.com/pleme-io/k8s.git',
          reconcile_path: 'clusters/production'
        }
      ))
      expect(config.fluxcd).not_to be_nil
      expect(config.fluxcd.source_url).to eq('ssh://git@github.com/pleme-io/k8s.git')
      expect(config.fluxcd.reconcile_path).to eq('clusters/production')
    end

    it 'defaults fluxcd to nil' do
      config = described_class.new(minimal_attrs)
      expect(config.fluxcd).to be_nil
    end
  end

  describe 'NixOS configuration' do
    it 'accepts nixos config' do
      config = described_class.new(minimal_attrs.merge(
        nixos: { image_id: 'nixos-24-05', flake_url: 'github:pleme-io/blackmatter-kubernetes' }
      ))
      expect(config.nixos).not_to be_nil
      expect(config.nixos.image_id).to eq('nixos-24-05')
      expect(config.nixos.flake_url).to eq('github:pleme-io/blackmatter-kubernetes')
    end

    it 'defaults nixos to nil' do
      config = described_class.new(minimal_attrs)
      expect(config.nixos).to be_nil
    end
  end

  describe '#to_h' do
    it 'serializes to hash' do
      config = described_class.new(minimal_attrs)
      hash = config.to_h
      expect(hash[:backend]).to eq(:aws)
      expect(hash[:region]).to eq('us-east-1')
      expect(hash[:node_pools]).to be_an(Array)
      expect(hash[:node_pools].first[:name]).to eq(:system)
    end

    it 'includes distribution and profile' do
      config = described_class.new(minimal_attrs.merge(distribution: :kubernetes, profile: 'calico-standard'))
      hash = config.to_h
      expect(hash[:distribution]).to eq(:kubernetes)
      expect(hash[:profile]).to eq('calico-standard')
    end

    it 'omits nil optional fields' do
      config = described_class.new(minimal_attrs)
      hash = config.to_h
      expect(hash).not_to have_key(:role_arn)
      expect(hash).not_to have_key(:project)
      expect(hash).not_to have_key(:ami_id)
    end
  end
end
