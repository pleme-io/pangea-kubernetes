# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::KernelConfig do
  describe 'defaults' do
    subject { described_class.new({}) }

    it 'defaults extra_modules to empty' do
      expect(subject.extra_modules).to eq([])
    end

    it 'defaults sysctl to empty' do
      expect(subject.sysctl).to eq({})
    end

    it 'defaults hardening to true' do
      expect(subject.hardening).to be true
    end
  end

  describe 'custom values' do
    subject do
      described_class.new(
        extra_modules: %w[br_netfilter overlay],
        sysctl: { 'net.ipv4.ip_forward' => '1' },
        hardening: false
      )
    end

    it 'accepts module lists' do
      expect(subject.extra_modules).to eq(%w[br_netfilter overlay])
    end

    it 'accepts sysctl parameters' do
      expect(subject.sysctl).to eq({ 'net.ipv4.ip_forward' => '1' })
    end
  end

  describe '#to_h' do
    it 'omits empty collections' do
      hash = described_class.new({}).to_h
      expect(hash).not_to have_key(:extra_modules)
      expect(hash).not_to have_key(:sysctl)
    end

    it 'always includes hardening' do
      hash = described_class.new({}).to_h
      expect(hash).to have_key(:hardening)
    end
  end
end
