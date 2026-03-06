# frozen_string_literal: true

RSpec.describe 'NodePoolConfig edge cases' do
  let(:minimal_attrs) do
    { name: :system, instance_types: ['t3.large'] }
  end

  describe 'max_pods' do
    it 'defaults to nil' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(minimal_attrs)
      expect(pool.max_pods).to be_nil
    end

    it 'accepts max_pods value' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(minimal_attrs.merge(max_pods: 110))
      expect(pool.max_pods).to eq(110)
    end

    it 'includes max_pods in to_h when set' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(minimal_attrs.merge(max_pods: 250))
      hash = pool.to_h
      expect(hash[:max_pods]).to eq(250)
    end

    it 'omits max_pods from to_h when nil' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(minimal_attrs)
      hash = pool.to_h
      expect(hash).not_to have_key(:max_pods)
    end
  end

  describe 'ssh_keys' do
    it 'accepts ssh_keys' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        minimal_attrs.merge(ssh_keys: ['key-1', 'key-2'])
      )
      expect(pool.ssh_keys).to eq(['key-1', 'key-2'])
    end

    it 'includes ssh_keys in to_h when non-empty' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        minimal_attrs.merge(ssh_keys: ['my-key'])
      )
      hash = pool.to_h
      expect(hash[:ssh_keys]).to eq(['my-key'])
    end

    it 'omits ssh_keys from to_h when empty' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(minimal_attrs)
      hash = pool.to_h
      expect(hash).not_to have_key(:ssh_keys)
    end
  end

  describe 'taints propagation' do
    it 'supports multiple taints' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        minimal_attrs.merge(
          taints: [
            { key: 'dedicated', value: 'gpu', effect: 'NoSchedule' },
            { key: 'workload', value: 'ml', effect: 'PreferNoSchedule' }
          ]
        )
      )
      expect(pool.taints.size).to eq(2)
      hash = pool.to_h
      expect(hash[:taints].size).to eq(2)
    end
  end

  describe 'labels propagation' do
    it 'supports multiple labels' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        minimal_attrs.merge(
          labels: { 'tier' => 'compute', 'gpu' => 'true', 'arch' => 'amd64' }
        )
      )
      expect(pool.labels.size).to eq(3)
      hash = pool.to_h
      expect(hash[:labels]).to eq({ 'tier' => 'compute', 'gpu' => 'true', 'arch' => 'amd64' })
    end
  end

  describe 'desired_size edge cases' do
    it 'allows desired_size equal to min_size' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        minimal_attrs.merge(min_size: 3, max_size: 10, desired_size: 3)
      )
      expect(pool.desired_size).to eq(3)
      expect(pool.effective_desired_size).to eq(3)
    end

    it 'allows desired_size equal to max_size' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        minimal_attrs.merge(min_size: 1, max_size: 5, desired_size: 5)
      )
      expect(pool.desired_size).to eq(5)
    end

    it 'allows min_size of 0' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        minimal_attrs.merge(min_size: 0, max_size: 5)
      )
      expect(pool.min_size).to eq(0)
      expect(pool.effective_desired_size).to eq(0)
    end
  end

  describe 'multiple instance types' do
    it 'accepts multiple instance types' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        minimal_attrs.merge(instance_types: ['t3.large', 't3.xlarge', 'm5.large'])
      )
      expect(pool.instance_types.size).to eq(3)
    end
  end

  describe 'string key coercion' do
    it 'handles string keys in hash' do
      pool = Pangea::Kubernetes::Types::NodePoolConfig.new(
        'name' => 'workers', 'instance_types' => ['c5.xlarge']
      )
      expect(pool.name).to eq(:workers)
      expect(pool.instance_types).to eq(['c5.xlarge'])
    end
  end
end
