# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Pangea::Kubernetes::NetworkBackendRegistry do
  describe '.resolve' do
    it 'resolves vpc_cni' do
      backend = described_class.resolve(:vpc_cni)
      expect(backend.backend_name).to eq(:vpc_cni)
    end

    it 'resolves cilium' do
      backend = described_class.resolve(:cilium)
      expect(backend.backend_name).to eq(:cilium)
    end

    it 'resolves aliases' do
      expect(described_class.resolve(:aws_cni).backend_name).to eq(:vpc_cni)
      expect(described_class.resolve(:ebpf).backend_name).to eq(:cilium)
    end

    it 'raises for unknown backend' do
      expect { described_class.resolve(:nonexistent) }.to raise_error(ArgumentError, /Unknown network backend/)
    end
  end

  describe '.compatible?' do
    it 'vpc_cni is compatible with aws only' do
      expect(described_class.compatible?(:vpc_cni, :aws)).to be true
      expect(described_class.compatible?(:vpc_cni, :gcp)).to be false
      expect(described_class.compatible?(:vpc_cni, :hcloud)).to be false
    end

    it 'cilium is compatible with all cloud backends' do
      expect(described_class.compatible?(:cilium, :aws)).to be true
      expect(described_class.compatible?(:cilium, :gcp)).to be true
      expect(described_class.compatible?(:cilium, :azure)).to be true
      expect(described_class.compatible?(:cilium, :hcloud)).to be true
    end
  end

  describe '.available' do
    it 'returns all registered backends' do
      expect(described_class.available).to contain_exactly(:vpc_cni, :cilium)
    end
  end

  describe 'backend capabilities' do
    it 'vpc_cni has no mesh or L7' do
      backend = described_class.resolve(:vpc_cni)
      expect(backend.mesh_capable?).to be false
      expect(backend.l7_observable?).to be false
    end

    it 'cilium has mesh and L7' do
      backend = described_class.resolve(:cilium)
      expect(backend.mesh_capable?).to be true
      expect(backend.l7_observable?).to be true
    end
  end

  describe 'cilium helm values' do
    let(:cilium) { described_class.resolve(:cilium) }

    it 'returns ENI mode values by default' do
      values = cilium.helm_values({})
      expect(values['ipam']['mode']).to eq('eni')
      expect(values['hubble']['enabled']).to be true
      expect(values['eni']['enabled']).to be true
    end

    it 'returns overlay mode when configured' do
      values = cilium.helm_values({ cilium_mode: :overlay })
      expect(values['ipam']['mode']).to eq('overlay')
      expect(values).not_to have_key('eni')
    end
  end
end
