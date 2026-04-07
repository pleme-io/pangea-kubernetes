# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::NetworkConfig do
  describe 'construction with defaults' do
    let(:config) { described_class.new({}) }

    it 'defaults vpc_cidr to nil' do
      expect(config.vpc_cidr).to be_nil
    end

    it 'defaults pod_cidr to nil' do
      expect(config.pod_cidr).to be_nil
    end

    it 'defaults service_cidr to nil' do
      expect(config.service_cidr).to be_nil
    end

    it 'defaults subnet_ids to empty array' do
      expect(config.subnet_ids).to eq([])
    end

    it 'defaults security_group_ids to empty array' do
      expect(config.security_group_ids).to eq([])
    end

    it 'defaults private_endpoint to true' do
      expect(config.private_endpoint).to be true
    end

    it 'defaults public_endpoint to false' do
      expect(config.public_endpoint).to be false
    end
  end

  describe '#to_h' do
    it 'always includes endpoint visibility' do
      config = described_class.new({})
      hash = config.to_h
      expect(hash[:private_endpoint]).to be true
      expect(hash[:public_endpoint]).to be false
    end

    it 'omits vpc_cidr when nil' do
      config = described_class.new({})
      expect(config.to_h).not_to have_key(:vpc_cidr)
    end

    it 'includes vpc_cidr when set' do
      config = described_class.new(vpc_cidr: '10.0.0.0/16')
      expect(config.to_h[:vpc_cidr]).to eq('10.0.0.0/16')
    end

    it 'omits pod_cidr when nil' do
      config = described_class.new({})
      expect(config.to_h).not_to have_key(:pod_cidr)
    end

    it 'includes pod_cidr when set' do
      config = described_class.new(pod_cidr: '172.16.0.0/16')
      expect(config.to_h[:pod_cidr]).to eq('172.16.0.0/16')
    end

    it 'omits subnet_ids when empty' do
      config = described_class.new({})
      expect(config.to_h).not_to have_key(:subnet_ids)
    end

    it 'includes subnet_ids when non-empty' do
      config = described_class.new(subnet_ids: ['subnet-123'])
      expect(config.to_h[:subnet_ids]).to eq(['subnet-123'])
    end

    it 'omits security_group_ids when empty' do
      config = described_class.new({})
      expect(config.to_h).not_to have_key(:security_group_ids)
    end

    it 'includes security_group_ids when non-empty' do
      config = described_class.new(security_group_ids: ['sg-123'])
      expect(config.to_h[:security_group_ids]).to eq(['sg-123'])
    end
  end

  describe 'public endpoint configuration' do
    it 'supports both endpoints enabled' do
      config = described_class.new(private_endpoint: true, public_endpoint: true)
      expect(config.private_endpoint).to be true
      expect(config.public_endpoint).to be true
    end

    it 'supports neither endpoint' do
      config = described_class.new(private_endpoint: false, public_endpoint: false)
      expect(config.private_endpoint).to be false
      expect(config.public_endpoint).to be false
    end
  end
end
