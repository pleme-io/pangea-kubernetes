# frozen_string_literal: true

RSpec.describe 'Cross-Backend Interface Parity' do
  include SynthesisTestHelpers

  let(:managed_backends) do
    [
      Pangea::Kubernetes::Backends::AwsEks,
      Pangea::Kubernetes::Backends::GcpGke,
      Pangea::Kubernetes::Backends::AzureAks
    ]
  end

  let(:nixos_backends) do
    [
      Pangea::Kubernetes::Backends::AwsNixos,
      Pangea::Kubernetes::Backends::GcpNixos,
      Pangea::Kubernetes::Backends::AzureNixos,
      Pangea::Kubernetes::Backends::HcloudK3s
    ]
  end

  let(:all_backends) { managed_backends + nixos_backends }

  describe 'class interface' do
    it 'all backends respond to .backend_name' do
      all_backends.each do |backend|
        expect(backend).to respond_to(:backend_name)
        expect(backend.backend_name).to be_a(Symbol)
      end
    end

    it 'all backends respond to .managed_kubernetes?' do
      all_backends.each do |backend|
        expect(backend).to respond_to(:managed_kubernetes?)
        expect([true, false]).to include(backend.managed_kubernetes?)
      end
    end

    it 'all backends respond to .required_gem' do
      all_backends.each do |backend|
        expect(backend).to respond_to(:required_gem)
        expect(backend.required_gem).to be_a(String)
      end
    end

    it 'all backends respond to .create_cluster' do
      all_backends.each do |backend|
        expect(backend).to respond_to(:create_cluster)
      end
    end

    it 'all backends respond to .create_node_pool' do
      all_backends.each do |backend|
        expect(backend).to respond_to(:create_node_pool)
      end
    end

    it 'all backends respond to .create_network' do
      all_backends.each do |backend|
        expect(backend).to respond_to(:create_network)
      end
    end

    it 'all backends respond to .create_iam' do
      all_backends.each do |backend|
        expect(backend).to respond_to(:create_iam)
      end
    end

    it 'all backends respond to .load_provider!' do
      all_backends.each do |backend|
        expect(backend).to respond_to(:load_provider!)
      end
    end
  end

  describe 'backend naming' do
    it 'each backend has a unique name' do
      names = all_backends.map(&:backend_name)
      expect(names.uniq).to eq(names)
    end

    it 'backend names match registry keys' do
      expected_names = %i[aws gcp azure aws_nixos gcp_nixos azure_nixos hcloud]
      actual_names = all_backends.map(&:backend_name)
      expect(actual_names).to contain_exactly(*expected_names)
    end
  end

  describe 'managed vs unmanaged' do
    it 'EKS, GKE, AKS are managed' do
      expect(Pangea::Kubernetes::Backends::AwsEks.managed_kubernetes?).to be true
      expect(Pangea::Kubernetes::Backends::GcpGke.managed_kubernetes?).to be true
      expect(Pangea::Kubernetes::Backends::AzureAks.managed_kubernetes?).to be true
    end

    it 'all NixOS backends are unmanaged' do
      nixos_backends.each do |backend|
        expect(backend.managed_kubernetes?).to(be(false),
          "Expected #{backend.backend_name} to be unmanaged")
      end
    end
  end

  describe 'required gems' do
    it 'each backend requires its provider gem' do
      expected = {
        aws: 'pangea-aws',
        gcp: 'pangea-gcp',
        azure: 'pangea-azure',
        aws_nixos: 'pangea-aws',
        gcp_nixos: 'pangea-gcp',
        azure_nixos: 'pangea-azure',
        hcloud: 'pangea-hcloud'
      }

      all_backends.each do |backend|
        expect(backend.required_gem).to eq(expected[backend.backend_name]),
          "#{backend.backend_name} should require #{expected[backend.backend_name]}"
      end
    end
  end

  describe 'create_network returns a hash' do
    let(:tags) { { ManagedBy: 'Pangea' } }

    it 'all backends return a hash from create_network' do
      configs = {
        aws: { backend: :aws, region: 'us-east-1', node_pools: [{ name: :system, instance_types: ['t3.large'] }], network: { vpc_cidr: '10.0.0.0/16' } },
        gcp: { backend: :gcp, region: 'us-central1', project: 'test', node_pools: [{ name: :system, instance_types: ['e2-standard-4'] }], network: { vpc_cidr: '10.0.0.0/20' } },
        azure: { backend: :azure, region: 'eastus', node_pools: [{ name: :system, instance_types: ['Standard_D4s_v3'] }], network: { vpc_cidr: '10.0.0.0/16' } },
        aws_nixos: { backend: :aws_nixos, region: 'us-east-1', node_pools: [{ name: :system, instance_types: ['t3.large'] }], network: { vpc_cidr: '10.0.0.0/16' } },
        gcp_nixos: { backend: :gcp_nixos, region: 'us-central1', project: 'test', node_pools: [{ name: :system, instance_types: ['e2-standard-4'] }], network: { vpc_cidr: '10.0.0.0/20' } },
        azure_nixos: { backend: :azure_nixos, region: 'eastus', node_pools: [{ name: :system, instance_types: ['Standard_D4s_v3'] }], network: { vpc_cidr: '10.0.0.0/16' } },
        hcloud: { backend: :hcloud, region: 'eu-central', node_pools: [{ name: :system, instance_types: ['cx41'] }], network: { vpc_cidr: '10.0.0.0/16' } }
      }

      all_backends.each do |backend|
        config = Pangea::Kubernetes::Types::ClusterConfig.new(configs[backend.backend_name])
        result = backend.create_network(create_mock_context, :test, config, tags)
        expect(result).to be_a(Hash), "#{backend.backend_name} create_network should return Hash"
      end
    end
  end

  describe 'create_iam returns a hash' do
    let(:tags) { { ManagedBy: 'Pangea' } }

    it 'all backends return a hash from create_iam' do
      all_backends.each do |backend|
        config_attrs = {
          backend: backend.backend_name, region: 'us-east-1',
          node_pools: [{ name: :system, instance_types: ['t3.large'] }]
        }
        # aws_nixos requires account_id in tags for IAM policy scoping
        config_attrs[:tags] = { account_id: '123456789012' } if backend.backend_name == :aws_nixos

        config = Pangea::Kubernetes::Types::ClusterConfig.new(config_attrs)
        result = backend.create_iam(create_mock_context, :test, config, tags)
        expect(result).to be_a(Hash), "#{backend.backend_name} create_iam should return Hash"
      end
    end
  end

  describe 'NixOS backend parity' do
    it 'all NixOS backends use same CloudInit module' do
      nixos_backends.each do |backend|
        # NixOS backends produce cloud-init with distribution/profile keys
        ctx = create_mock_context
        config_attrs = {
          backend: backend.backend_name,
          kubernetes_version: '1.34',
          region: 'us-east-1',
          distribution: :k3s,
          profile: 'cilium-standard',
          node_pools: [{ name: :system, instance_types: ['t3.large'], min_size: 1, max_size: 1 }],
          network: { vpc_cidr: '10.0.0.0/16' }
        }
        config_attrs[:project] = 'test' if backend.backend_name == :gcp_nixos
        config_attrs[:ami_id] = 'ami-test' if backend.backend_name == :aws_nixos
        config_attrs[:azure_image_id] = '/sub/.../nixos' if backend.backend_name == :azure_nixos

        config = Pangea::Kubernetes::Types::ClusterConfig.new(config_attrs)
        arch_result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
        arch_result.network = backend.create_network(ctx, :test, config, { ManagedBy: 'Pangea' })
        if backend.respond_to?(:create_iam) && backend.backend_name == :gcp_nixos
          arch_result.iam = backend.create_iam(ctx, :test, config, { ManagedBy: 'Pangea' })
        end

        backend.create_cluster(ctx, :test, config, arch_result, { ManagedBy: 'Pangea' })

        # Find the control-plane resource — ASG-based backends use launch template, others use instance
        cp_resource = if backend.backend_name == :aws_nixos
          ctx.created_resources.find { |r| r[:name] == :test_cp_lt }
        else
          ctx.created_resources.find { |r| r[:name] == :test_cp_0 }
        end
        expect(cp_resource).not_to be_nil, "#{backend.backend_name} should create control plane resource"

        user_data = cp_resource[:attrs].dig(:launch_template_data, :user_data) || cp_resource[:attrs][:user_data] || cp_resource[:attrs][:custom_data] || cp_resource[:attrs].dig(:metadata, 'user-data')
        expect(user_data).to include('"distribution":"k3s"'),
          "#{backend.backend_name} should include distribution in cloud-init"
        expect(user_data).to include('"profile":"cilium-standard"'),
          "#{backend.backend_name} should include profile in cloud-init"
      end
    end
  end
end
