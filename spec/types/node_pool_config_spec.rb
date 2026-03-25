# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Types::NodePoolConfig do
  let(:minimal_attrs) do
    { name: :system, instance_types: ['t3.large'] }
  end

  describe 'creation' do
    it 'creates with minimal attributes' do
      pool = described_class.new(minimal_attrs)
      expect(pool.name).to eq(:system)
      expect(pool.instance_types).to eq(['t3.large'])
    end

    it 'requires at least one instance type' do
      expect {
        described_class.new(name: :system, instance_types: [])
      }.to raise_error(Dry::Struct::Error)
    end

    it 'rejects max_size < min_size' do
      expect {
        described_class.new(minimal_attrs.merge(min_size: 5, max_size: 2))
      }.to raise_error(Dry::Struct::Error)
    end

    it 'rejects negative min_size' do
      expect {
        described_class.new(minimal_attrs.merge(min_size: -1))
      }.to raise_error(Dry::Struct::Error)
    end

    it 'rejects disk_size_gb < 10' do
      expect {
        described_class.new(minimal_attrs.merge(disk_size_gb: 5))
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'defaults' do
    it 'defaults min_size to 1' do
      pool = described_class.new(minimal_attrs)
      expect(pool.min_size).to eq(1)
    end

    it 'defaults max_size to 3' do
      pool = described_class.new(minimal_attrs)
      expect(pool.max_size).to eq(3)
    end

    it 'defaults disk_size_gb to 20' do
      pool = described_class.new(minimal_attrs)
      expect(pool.disk_size_gb).to eq(20)
    end

    it 'defaults labels to empty hash' do
      pool = described_class.new(minimal_attrs)
      expect(pool.labels).to eq({})
    end

    it 'defaults taints to empty array' do
      pool = described_class.new(minimal_attrs)
      expect(pool.taints).to eq([])
    end

    it 'defaults ssh_keys to empty array' do
      pool = described_class.new(minimal_attrs)
      expect(pool.ssh_keys).to eq([])
    end
  end

  describe '#effective_desired_size' do
    it 'returns desired_size when set' do
      pool = described_class.new(minimal_attrs.merge(desired_size: 5))
      expect(pool.effective_desired_size).to eq(5)
    end

    it 'falls back to min_size when desired_size not set' do
      pool = described_class.new(minimal_attrs.merge(min_size: 3))
      expect(pool.effective_desired_size).to eq(3)
    end
  end

  describe '#to_h' do
    it 'serializes required fields' do
      pool = described_class.new(minimal_attrs)
      hash = pool.to_h
      expect(hash[:name]).to eq(:system)
      expect(hash[:instance_types]).to eq(['t3.large'])
      expect(hash[:min_size]).to eq(1)
      expect(hash[:max_size]).to eq(3)
      expect(hash[:disk_size_gb]).to eq(20)
    end

    it 'omits empty optional fields' do
      pool = described_class.new(minimal_attrs)
      hash = pool.to_h
      expect(hash).not_to have_key(:labels)
      expect(hash).not_to have_key(:taints)
      expect(hash).not_to have_key(:desired_size)
    end

    it 'includes optional fields when set' do
      pool = described_class.new(minimal_attrs.merge(
        labels: { 'role' => 'worker' },
        taints: [{ key: 'dedicated', value: 'gpu', effect: 'NoSchedule' }],
        desired_size: 5
      ))
      hash = pool.to_h
      expect(hash[:labels]).to eq({ 'role' => 'worker' })
      expect(hash[:taints].size).to eq(1)
      expect(hash[:desired_size]).to eq(5)
    end
  end
end
