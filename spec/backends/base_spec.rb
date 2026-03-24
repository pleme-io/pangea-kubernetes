# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Backends::Base do
  # Create a test module that includes Base but does not implement the abstract methods
  let(:unimplemented_backend) do
    mod = Module.new
    mod.include(described_class)
    mod
  end

  describe 'ClassMethods' do
    describe '.backend_name' do
      it 'raises NotImplementedError when not overridden' do
        expect { unimplemented_backend.backend_name }.to raise_error(NotImplementedError, /must implement .backend_name/)
      end
    end

    describe '.managed_kubernetes?' do
      it 'raises NotImplementedError when not overridden' do
        expect { unimplemented_backend.managed_kubernetes? }.to raise_error(NotImplementedError, /must implement .managed_kubernetes?/)
      end
    end

    describe '.required_gem' do
      it 'raises NotImplementedError when not overridden' do
        expect { unimplemented_backend.required_gem }.to raise_error(NotImplementedError, /must implement .required_gem/)
      end
    end

    describe '.load_provider!' do
      it 'raises LoadError with helpful message when gem not found' do
        mod = Module.new do
          include Pangea::Kubernetes::Backends::Base

          class << self
            def backend_name = :test_backend
            def managed_kubernetes? = false
            def required_gem = 'pangea-nonexistent-gem-xyz'
          end
        end

        expect { mod.load_provider! }.to raise_error(LoadError, /requires gem 'pangea-nonexistent-gem-xyz'/)
      end
    end
  end

  describe 'class-level pipeline methods' do
    describe '.create_network' do
      it 'raises NotImplementedError' do
        expect { unimplemented_backend.create_network(nil, nil, nil, nil) }.to raise_error(NotImplementedError, /must implement .create_network/)
      end
    end

    describe '.create_iam' do
      it 'raises NotImplementedError' do
        expect { unimplemented_backend.create_iam(nil, nil, nil, nil) }.to raise_error(NotImplementedError, /must implement .create_iam/)
      end
    end

    describe '.create_cluster' do
      it 'raises NotImplementedError' do
        expect { unimplemented_backend.create_cluster(nil, nil, nil, nil, nil) }.to raise_error(NotImplementedError, /must implement .create_cluster/)
      end
    end

    describe '.create_node_pool' do
      it 'raises NotImplementedError' do
        expect { unimplemented_backend.create_node_pool(nil, nil, nil, nil, nil) }.to raise_error(NotImplementedError, /must implement .create_node_pool/)
      end
    end
  end
end
