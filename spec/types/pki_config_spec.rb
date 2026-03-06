# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::PKIConfig do
  describe 'defaults' do
    subject { described_class.new({}) }

    it 'defaults mode to auto' do
      expect(subject.mode).to eq('auto')
    end

    it 'defaults cert_validity_days to 365' do
      expect(subject.cert_validity_days).to eq(365)
    end

    it 'defaults cert_dir' do
      expect(subject.cert_dir).to eq('/etc/kubernetes/pki')
    end

    it 'defaults api_server_extra_sans to empty' do
      expect(subject.api_server_extra_sans).to eq([])
    end
  end

  describe 'validation' do
    it 'accepts auto mode' do
      expect(described_class.new(mode: 'auto').mode).to eq('auto')
    end

    it 'accepts manual mode' do
      expect(described_class.new(mode: 'manual').mode).to eq('manual')
    end

    it 'accepts external mode' do
      expect(described_class.new(mode: 'external').mode).to eq('external')
    end

    it 'rejects invalid mode' do
      expect { described_class.new(mode: 'custom') }.to raise_error(Dry::Struct::Error)
    end

    it 'rejects cert_validity_days < 1' do
      expect { described_class.new(cert_validity_days: 0) }.to raise_error(Dry::Struct::Error)
    end
  end

  describe '#to_h' do
    it 'omits nil cert paths' do
      hash = described_class.new({}).to_h
      expect(hash).not_to have_key(:ca_cert_path)
      expect(hash).not_to have_key(:ca_key_path)
    end

    it 'includes manual cert paths' do
      config = described_class.new(
        mode: 'manual',
        ca_cert_path: '/pki/ca.pem',
        ca_key_path: '/pki/ca-key.pem',
        api_server_extra_sans: ['api.example.com', '10.0.0.1']
      )
      hash = config.to_h
      expect(hash[:ca_cert_path]).to eq('/pki/ca.pem')
      expect(hash[:api_server_extra_sans]).to eq(['api.example.com', '10.0.0.1'])
    end
  end
end
