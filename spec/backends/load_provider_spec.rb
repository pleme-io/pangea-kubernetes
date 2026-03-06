# frozen_string_literal: true

RSpec.describe 'Backend load_provider! error handling' do
  # Each backend has its own load_provider! with a specific error message.
  # We test by stubbing require to fail.

  describe Pangea::Kubernetes::Backends::AwsEks do
    it 'raises LoadError with helpful message when pangea-aws not available' do
      allow(described_class).to receive(:require).with('pangea-aws').and_raise(LoadError.new('cannot load such file'))
      expect { described_class.load_provider! }.to raise_error(LoadError, /Backend :aws requires gem 'pangea-aws'/)
    end

    it 'includes original error message in LoadError' do
      allow(described_class).to receive(:require).with('pangea-aws').and_raise(LoadError.new('original error message'))
      expect { described_class.load_provider! }.to raise_error(LoadError, /Original error: original error message/)
    end
  end

  describe Pangea::Kubernetes::Backends::GcpGke do
    it 'raises LoadError with helpful message when pangea-gcp not available' do
      allow(described_class).to receive(:require).with('pangea-gcp').and_raise(LoadError.new('cannot load such file'))
      expect { described_class.load_provider! }.to raise_error(LoadError, /Backend :gcp requires gem 'pangea-gcp'/)
    end
  end

  describe Pangea::Kubernetes::Backends::AzureAks do
    it 'raises LoadError with helpful message when pangea-azure not available' do
      allow(described_class).to receive(:require).with('pangea-azure').and_raise(LoadError.new('cannot load such file'))
      expect { described_class.load_provider! }.to raise_error(LoadError, /Backend :azure requires gem 'pangea-azure'/)
    end
  end

  describe Pangea::Kubernetes::Backends::HcloudK3s do
    it 'raises LoadError with helpful message when pangea-hcloud not available' do
      allow(described_class).to receive(:require).with('pangea-hcloud').and_raise(LoadError.new('cannot load such file'))
      expect { described_class.load_provider! }.to raise_error(LoadError, /Backend :hcloud requires gem 'pangea-hcloud'/)
    end
  end

  describe Pangea::Kubernetes::Backends::AwsNixos do
    it 'raises LoadError with helpful message when pangea-aws not available' do
      allow(described_class).to receive(:require).with('pangea-aws').and_raise(LoadError.new('cannot load such file'))
      expect { described_class.load_provider! }.to raise_error(LoadError, /Backend :aws_nixos requires gem 'pangea-aws'/)
    end
  end

  describe Pangea::Kubernetes::Backends::GcpNixos do
    it 'raises LoadError with helpful message when pangea-gcp not available' do
      allow(described_class).to receive(:require).with('pangea-gcp').and_raise(LoadError.new('cannot load such file'))
      expect { described_class.load_provider! }.to raise_error(LoadError, /Backend :gcp_nixos requires gem 'pangea-gcp'/)
    end
  end

  describe Pangea::Kubernetes::Backends::AzureNixos do
    it 'raises LoadError with helpful message when pangea-azure not available' do
      allow(described_class).to receive(:require).with('pangea-azure').and_raise(LoadError.new('cannot load such file'))
      expect { described_class.load_provider! }.to raise_error(LoadError, /Backend :azure_nixos requires gem 'pangea-azure'/)
    end
  end
end
