# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::AddonConfig do
  describe 'construction' do
    it 'constructs with required name' do
      addon = described_class.new(name: :ingress)
      expect(addon.name).to eq(:ingress)
    end

    it 'coerces string name to symbol' do
      addon = described_class.new(name: 'monitoring')
      expect(addon.name).to eq(:monitoring)
    end

    it 'defaults enabled to true' do
      addon = described_class.new(name: :ingress)
      expect(addon.enabled).to be true
    end

    it 'defaults version to nil' do
      addon = described_class.new(name: :ingress)
      expect(addon.version).to be_nil
    end

    it 'defaults config to empty hash' do
      addon = described_class.new(name: :ingress)
      expect(addon.config).to eq({})
    end
  end

  describe 'custom values' do
    it 'accepts enabled false' do
      addon = described_class.new(name: :ingress, enabled: false)
      expect(addon.enabled).to be false
    end

    it 'accepts a version string' do
      addon = described_class.new(name: :ingress, version: '4.7.1')
      expect(addon.version).to eq('4.7.1')
    end

    it 'accepts a config hash' do
      addon = described_class.new(name: :ingress, config: { replicas: 3 })
      expect(addon.config[:replicas]).to eq(3)
    end
  end

  describe '#to_h' do
    it 'includes name and enabled' do
      addon = described_class.new(name: :ingress)
      hash = addon.to_h
      expect(hash[:name]).to eq(:ingress)
      expect(hash[:enabled]).to be true
    end

    it 'omits version when nil' do
      addon = described_class.new(name: :ingress)
      expect(addon.to_h).not_to have_key(:version)
    end

    it 'includes version when set' do
      addon = described_class.new(name: :ingress, version: '1.0')
      expect(addon.to_h[:version]).to eq('1.0')
    end

    it 'omits config when empty' do
      addon = described_class.new(name: :ingress)
      expect(addon.to_h).not_to have_key(:config)
    end

    it 'includes config when non-empty' do
      addon = described_class.new(name: :ingress, config: { foo: 'bar' })
      expect(addon.to_h[:config]).to eq({ foo: 'bar' })
    end
  end
end
