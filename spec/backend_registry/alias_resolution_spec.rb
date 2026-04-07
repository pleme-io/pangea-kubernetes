# frozen_string_literal: true

RSpec.describe 'BackendRegistry alias resolution' do
  after(:each) do
    Pangea::Kubernetes::BackendRegistry.reset!
  end

  describe '.resolve with canonical names' do
    it 'resolves aws_eks' do
      backend = Pangea::Kubernetes::BackendRegistry.resolve(:aws_eks)
      expect(backend).to eq(Pangea::Kubernetes::Backends::AwsEks)
    end

    it 'resolves aws_nixos_k3s' do
      backend = Pangea::Kubernetes::BackendRegistry.resolve(:aws_nixos_k3s)
      expect(backend).to eq(Pangea::Kubernetes::Backends::AwsNixos)
    end

    it 'resolves gcp_gke' do
      backend = Pangea::Kubernetes::BackendRegistry.resolve(:gcp_gke)
      expect(backend).to eq(Pangea::Kubernetes::Backends::GcpGke)
    end

    it 'resolves gcp_nixos_k3s' do
      backend = Pangea::Kubernetes::BackendRegistry.resolve(:gcp_nixos_k3s)
      expect(backend).to eq(Pangea::Kubernetes::Backends::GcpNixos)
    end

    it 'resolves azure_aks' do
      backend = Pangea::Kubernetes::BackendRegistry.resolve(:azure_aks)
      expect(backend).to eq(Pangea::Kubernetes::Backends::AzureAks)
    end

    it 'resolves azure_nixos_k3s' do
      backend = Pangea::Kubernetes::BackendRegistry.resolve(:azure_nixos_k3s)
      expect(backend).to eq(Pangea::Kubernetes::Backends::AzureNixos)
    end

    it 'resolves hcloud_k3s' do
      backend = Pangea::Kubernetes::BackendRegistry.resolve(:hcloud_k3s)
      expect(backend).to eq(Pangea::Kubernetes::Backends::HcloudK3s)
    end
  end

  describe '.resolve with legacy aliases' do
    it 'resolves :aws to AwsEks' do
      expect(Pangea::Kubernetes::BackendRegistry.resolve(:aws)).to eq(Pangea::Kubernetes::Backends::AwsEks)
    end

    it 'resolves :aws_nixos to AwsNixos' do
      expect(Pangea::Kubernetes::BackendRegistry.resolve(:aws_nixos)).to eq(Pangea::Kubernetes::Backends::AwsNixos)
    end

    it 'resolves :gcp to GcpGke' do
      expect(Pangea::Kubernetes::BackendRegistry.resolve(:gcp)).to eq(Pangea::Kubernetes::Backends::GcpGke)
    end

    it 'resolves :gcp_nixos to GcpNixos' do
      expect(Pangea::Kubernetes::BackendRegistry.resolve(:gcp_nixos)).to eq(Pangea::Kubernetes::Backends::GcpNixos)
    end

    it 'resolves :azure to AzureAks' do
      expect(Pangea::Kubernetes::BackendRegistry.resolve(:azure)).to eq(Pangea::Kubernetes::Backends::AzureAks)
    end

    it 'resolves :azure_nixos to AzureNixos' do
      expect(Pangea::Kubernetes::BackendRegistry.resolve(:azure_nixos)).to eq(Pangea::Kubernetes::Backends::AzureNixos)
    end

    it 'resolves :hcloud to HcloudK3s' do
      expect(Pangea::Kubernetes::BackendRegistry.resolve(:hcloud)).to eq(Pangea::Kubernetes::Backends::HcloudK3s)
    end
  end

  describe '.all_names' do
    it 'returns both canonical names and aliases' do
      names = Pangea::Kubernetes::BackendRegistry.all_names
      expect(names).to include(:aws_eks)
      expect(names).to include(:aws)
      expect(names).to include(:hcloud_k3s)
      expect(names).to include(:hcloud)
    end

    it 'has no duplicates' do
      names = Pangea::Kubernetes::BackendRegistry.all_names
      expect(names.uniq.length).to eq(names.length)
    end

    it 'includes all BACKEND_MAP keys' do
      Pangea::Kubernetes::BackendRegistry::BACKEND_MAP.keys.each do |key|
        expect(Pangea::Kubernetes::BackendRegistry.all_names).to include(key)
      end
    end

    it 'includes all ALIASES keys' do
      Pangea::Kubernetes::BackendRegistry::ALIASES.keys.each do |key|
        expect(Pangea::Kubernetes::BackendRegistry.all_names).to include(key)
      end
    end
  end

  describe 'alias targets match BACKEND_MAP entries' do
    Pangea::Kubernetes::BackendRegistry::ALIASES.each do |alias_name, canonical_name|
      it "alias :#{alias_name} points to valid canonical name :#{canonical_name}" do
        expect(Pangea::Kubernetes::BackendRegistry::BACKEND_MAP).to have_key(canonical_name)
      end
    end
  end

  describe 'alias and canonical resolve to the same module' do
    { aws: :aws_eks, aws_nixos: :aws_nixos_k3s, gcp: :gcp_gke,
      azure: :azure_aks, hcloud: :hcloud_k3s }.each do |alias_name, canonical|
      it ":#{alias_name} and :#{canonical} resolve to same backend" do
        alias_backend = Pangea::Kubernetes::BackendRegistry.resolve(alias_name)
        canonical_backend = Pangea::Kubernetes::BackendRegistry.resolve(canonical)
        expect(alias_backend).to eq(canonical_backend)
      end
    end
  end
end
