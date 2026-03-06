# frozen_string_literal: true

RSpec.describe 'ClusterConfig#to_h edge cases' do
  let(:base_attrs) do
    {
      backend: :aws,
      region: 'us-east-1',
      node_pools: [{ name: :system, instance_types: ['t3.large'] }]
    }
  end

  describe 'optional field inclusion in to_h' do
    it 'includes network when set' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(network: { vpc_cidr: '10.0.0.0/16' })
      )
      hash = config.to_h
      expect(hash[:network]).to be_a(Hash)
      expect(hash[:network][:vpc_cidr]).to eq('10.0.0.0/16')
    end

    it 'omits network when nil' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      hash = config.to_h
      expect(hash).not_to have_key(:network)
    end

    it 'includes addons when non-empty' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(addons: [:ingress, :monitoring])
      )
      hash = config.to_h
      expect(hash[:addons]).to eq([:ingress, :monitoring])
    end

    it 'omits addons when empty' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      hash = config.to_h
      expect(hash).not_to have_key(:addons)
    end

    it 'includes tags when non-empty' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(tags: { Environment: 'prod' })
      )
      hash = config.to_h
      expect(hash[:tags]).to eq({ Environment: 'prod' })
    end

    it 'omits tags when empty' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      hash = config.to_h
      expect(hash).not_to have_key(:tags)
    end

    it 'always includes encryption_at_rest' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      hash = config.to_h
      expect(hash[:encryption_at_rest]).to be true
    end

    it 'includes logging when non-empty' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(logging: ['api', 'audit'])
      )
      hash = config.to_h
      expect(hash[:logging]).to eq(['api', 'audit'])
    end

    it 'omits logging when empty' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      hash = config.to_h
      expect(hash).not_to have_key(:logging)
    end

    it 'includes distribution_track when set' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(distribution_track: '1.34')
      )
      hash = config.to_h
      expect(hash[:distribution_track]).to eq('1.34')
    end

    it 'omits distribution_track when nil' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      hash = config.to_h
      expect(hash).not_to have_key(:distribution_track)
    end

    it 'includes fluxcd when set' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(
          fluxcd: { source_url: 'ssh://git@github.com/org/k8s.git' }
        )
      )
      hash = config.to_h
      expect(hash[:fluxcd]).to be_a(Hash)
      expect(hash[:fluxcd][:source_url]).to eq('ssh://git@github.com/org/k8s.git')
    end

    it 'omits fluxcd when nil' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      hash = config.to_h
      expect(hash).not_to have_key(:fluxcd)
    end

    it 'includes nixos when set' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(nixos: { image_id: 'nixos-24-05' })
      )
      hash = config.to_h
      expect(hash[:nixos]).to be_a(Hash)
      expect(hash[:nixos][:image_id]).to eq('nixos-24-05')
    end

    it 'omits nixos when nil' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      hash = config.to_h
      expect(hash).not_to have_key(:nixos)
    end

    it 'includes role_arn when set' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(role_arn: 'arn:aws:iam::123:role/eks')
      )
      hash = config.to_h
      expect(hash[:role_arn]).to eq('arn:aws:iam::123:role/eks')
    end

    it 'includes ami_id when set' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(backend: :aws_nixos, ami_id: 'ami-test')
      )
      hash = config.to_h
      expect(hash[:ami_id]).to eq('ami-test')
    end

    it 'includes key_pair when set' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(backend: :aws_nixos, key_pair: 'my-key')
      )
      hash = config.to_h
      expect(hash[:key_pair]).to eq('my-key')
    end

    it 'includes project when set' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(backend: :gcp, project: 'my-project')
      )
      hash = config.to_h
      expect(hash[:project]).to eq('my-project')
    end

    it 'includes gce_image when set' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(backend: :gcp_nixos, gce_image: 'nixos-img')
      )
      hash = config.to_h
      expect(hash[:gce_image]).to eq('nixos-img')
    end

    it 'includes resource_group_name when set' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(backend: :azure, resource_group_name: 'my-rg')
      )
      hash = config.to_h
      expect(hash[:resource_group_name]).to eq('my-rg')
    end

    it 'includes dns_prefix when set' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(backend: :azure, dns_prefix: 'myaks')
      )
      hash = config.to_h
      expect(hash[:dns_prefix]).to eq('myaks')
    end

    it 'includes azure_image_id when set' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(backend: :azure_nixos, azure_image_id: '/sub/.../nixos')
      )
      hash = config.to_h
      expect(hash[:azure_image_id]).to eq('/sub/.../nixos')
    end
  end
end
