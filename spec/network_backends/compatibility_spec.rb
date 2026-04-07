# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Network backend compatibility matrix' do
  describe Pangea::Kubernetes::NetworkBackendRegistry do
    describe '.compatible? edge cases' do
      it 'vpc_cni is not compatible with gcp_nixos' do
        expect(described_class.compatible?(:vpc_cni, :gcp_nixos)).to be false
      end

      it 'vpc_cni is not compatible with azure_nixos' do
        expect(described_class.compatible?(:vpc_cni, :azure_nixos)).to be false
      end

      it 'cilium is compatible with aws_nixos' do
        expect(described_class.compatible?(:cilium, :aws_nixos)).to be true
      end

      it 'cilium is compatible with gcp_nixos' do
        expect(described_class.compatible?(:cilium, :gcp_nixos)).to be true
      end

      it 'cilium is compatible with azure_nixos' do
        expect(described_class.compatible?(:cilium, :azure_nixos)).to be true
      end
    end

    describe '.resolve with aliases' do
      it 'resolves :eni to vpc_cni' do
        backend = described_class.resolve(:eni)
        expect(backend.backend_name).to eq(:vpc_cni)
      end

      it 'resolves :aws_cni to vpc_cni' do
        backend = described_class.resolve(:aws_cni)
        expect(backend.backend_name).to eq(:vpc_cni)
      end

      it 'resolves :ebpf to cilium' do
        backend = described_class.resolve(:ebpf)
        expect(backend.backend_name).to eq(:cilium)
      end
    end

    describe '.resolve error message' do
      it 'includes available backends in error message' do
        expect {
          described_class.resolve(:calico)
        }.to raise_error(ArgumentError, /Available:.*vpc_cni.*cilium/)
      end
    end

    describe '.available returns frozen keys' do
      it 'returns an array' do
        expect(described_class.available).to be_an(Array)
      end

      it 'contains all registered backends' do
        expect(described_class.available).to contain_exactly(:vpc_cni, :cilium)
      end
    end
  end
end
