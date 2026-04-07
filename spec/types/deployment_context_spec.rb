# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::DeploymentContext do
  describe 'construction' do
    it 'constructs with required fields' do
      ctx = described_class.new(environment: :production, cluster_name: :prod)
      expect(ctx.environment).to eq(:production)
      expect(ctx.cluster_name).to eq(:prod)
    end

    it 'coerces string environment to symbol' do
      ctx = described_class.new(environment: 'staging', cluster_name: 'dev')
      expect(ctx.environment).to eq(:staging)
      expect(ctx.cluster_name).to eq(:dev)
    end

    it 'defaults team to nil' do
      ctx = described_class.new(environment: :production, cluster_name: :prod)
      expect(ctx.team).to be_nil
    end

    it 'defaults cost_center to nil' do
      ctx = described_class.new(environment: :production, cluster_name: :prod)
      expect(ctx.cost_center).to be_nil
    end
  end

  describe 'environment validation' do
    it 'accepts production' do
      expect { described_class.new(environment: :production, cluster_name: :a) }.not_to raise_error
    end

    it 'accepts staging' do
      expect { described_class.new(environment: :staging, cluster_name: :a) }.not_to raise_error
    end

    it 'accepts development' do
      expect { described_class.new(environment: :development, cluster_name: :a) }.not_to raise_error
    end

    it 'rejects invalid environment' do
      expect {
        described_class.new(environment: :testing, cluster_name: :a)
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe '#to_h' do
    it 'includes required fields' do
      ctx = described_class.new(environment: :production, cluster_name: :prod)
      hash = ctx.to_h
      expect(hash[:environment]).to eq(:production)
      expect(hash[:cluster_name]).to eq(:prod)
    end

    it 'omits team when nil' do
      ctx = described_class.new(environment: :production, cluster_name: :prod)
      expect(ctx.to_h).not_to have_key(:team)
    end

    it 'includes team when set' do
      ctx = described_class.new(environment: :production, cluster_name: :prod, team: 'infra')
      expect(ctx.to_h[:team]).to eq('infra')
    end

    it 'omits cost_center when nil' do
      ctx = described_class.new(environment: :production, cluster_name: :prod)
      expect(ctx.to_h).not_to have_key(:cost_center)
    end

    it 'includes cost_center when set' do
      ctx = described_class.new(environment: :staging, cluster_name: :dev, cost_center: 'CC-123')
      expect(ctx.to_h[:cost_center]).to eq('CC-123')
    end
  end

  describe 'string key coercion' do
    it 'accepts string keys via transform_keys' do
      ctx = described_class.new('environment' => 'development', 'cluster_name' => 'test')
      expect(ctx.environment).to eq(:development)
      expect(ctx.cluster_name).to eq(:test)
    end
  end
end
