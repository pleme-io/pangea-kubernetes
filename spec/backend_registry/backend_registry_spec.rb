# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::BackendRegistry do
  after(:each) do
    # Reset registry state between tests
    described_class.reset!
  end

  describe '.register' do
    it 'registers a backend module' do
      fake_backend = Module.new
      described_class.register(:test_backend, fake_backend)
      expect(described_class.resolve(:test_backend)).to eq(fake_backend)
    end

    it 'accepts string names and converts to symbol' do
      fake_backend = Module.new
      described_class.register('string_backend', fake_backend)
      expect(described_class.resolve(:string_backend)).to eq(fake_backend)
    end

    it 'overwrites previously registered backend' do
      first = Module.new
      second = Module.new
      described_class.register(:test, first)
      described_class.register(:test, second)
      expect(described_class.resolve(:test)).to eq(second)
    end
  end

  describe '.resolve' do
    it 'returns cached backend without re-loading' do
      fake_backend = Module.new
      described_class.register(:aws, fake_backend)
      expect(described_class.resolve(:aws)).to eq(fake_backend)
    end

    it 'lazy-loads backend when not cached' do
      # After reset, resolving :hcloud should lazy-load it
      backend = described_class.resolve(:hcloud)
      expect(backend).to eq(Pangea::Kubernetes::Backends::HcloudK3s)
    end

    it 'caches loaded backend for subsequent calls' do
      described_class.resolve(:hcloud)
      # Second call should return same module without re-loading
      expect(described_class.resolve(:hcloud)).to eq(Pangea::Kubernetes::Backends::HcloudK3s)
    end

    it 'raises ArgumentError for unknown backend' do
      expect {
        described_class.resolve(:digitalocean)
      }.to raise_error(ArgumentError, /Unknown backend: digitalocean/)
    end

    it 'includes available backends in error message' do
      expect {
        described_class.resolve(:nonexistent)
      }.to raise_error(ArgumentError, /Available:/)
    end

    it 'converts string name to symbol' do
      backend = described_class.resolve('hcloud')
      expect(backend).to eq(Pangea::Kubernetes::Backends::HcloudK3s)
    end

    it 'resolves all built-in backends' do
      %i[aws gcp azure aws_nixos gcp_nixos azure_nixos hcloud].each do |name|
        backend = described_class.resolve(name)
        expect(backend).not_to be_nil, "Failed to resolve backend: #{name}"
      end
    end
  end

  describe '.available_backends' do
    it 'returns all supported backend keys' do
      backends = described_class.available_backends
      expect(backends).to contain_exactly(:aws, :gcp, :azure, :aws_nixos, :gcp_nixos, :azure_nixos, :hcloud)
    end

    it 'returns keys from BACKEND_MAP' do
      # available_backends returns BACKEND_MAP.keys which is an Array
      expect(described_class.available_backends).to be_an(Array)
    end
  end

  describe '.backend_available?' do
    it 'returns true for backends with available gems' do
      # hcloud gem is available in test environment
      expect(described_class.backend_available?(:hcloud)).to be true
    end

    it 'returns true for all loaded backends' do
      # All backends should be available since we load them in spec_helper
      %i[aws gcp azure aws_nixos gcp_nixos azure_nixos hcloud].each do |name|
        expect(described_class.backend_available?(name)).to be true
      end
    end
  end

  describe '.backend_available? with LoadError' do
    it 'returns false when backend gem is not available' do
      described_class.reset!
      # Stub load_backend (private) to raise LoadError, simulating a missing gem
      allow(described_class).to receive(:load_backend).and_raise(LoadError.new('cannot load such file'))
      expect(described_class.backend_available?(:hcloud)).to be false
    end
  end

  describe '.reset!' do
    it 'clears all registered backends' do
      described_class.register(:custom, Module.new)
      described_class.reset!
      # After reset, custom backend should not be found
      expect {
        described_class.resolve(:custom)
      }.to raise_error(ArgumentError)
    end

    it 'forces re-loading of built-in backends' do
      # First resolve caches it
      described_class.resolve(:hcloud)
      # Reset clears cache
      described_class.reset!
      # Resolving again should work (re-loads)
      expect(described_class.resolve(:hcloud)).to eq(Pangea::Kubernetes::Backends::HcloudK3s)
    end
  end
end
