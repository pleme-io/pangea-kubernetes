# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::WaitForDNSConfig do
  describe 'defaults' do
    subject { described_class.new({}) }

    it 'defaults enabled to false' do
      expect(subject.enabled).to be false
    end

    it 'defaults hostname to nil' do
      expect(subject.hostname).to be_nil
    end

    it 'defaults timeout_seconds to 300' do
      expect(subject.timeout_seconds).to eq(300)
    end

    it 'defaults retry_interval to 5' do
      expect(subject.retry_interval).to eq(5)
    end
  end

  describe 'validation' do
    it 'rejects timeout_seconds < 1' do
      expect { described_class.new(timeout_seconds: 0) }.to raise_error(Dry::Struct::Error)
    end

    it 'rejects retry_interval < 1' do
      expect { described_class.new(retry_interval: 0) }.to raise_error(Dry::Struct::Error)
    end
  end

  describe '#to_h' do
    it 'omits nil hostname' do
      hash = described_class.new({}).to_h
      expect(hash).not_to have_key(:hostname)
    end

    it 'includes hostname when set' do
      hash = described_class.new(hostname: 'api.cluster.local').to_h
      expect(hash[:hostname]).to eq('api.cluster.local')
    end
  end
end
