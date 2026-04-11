# frozen_string_literal: true

RSpec.describe 'external_network pass-through' do
  include SynthesisTestHelpers

  let(:synth) do
    ctx = create_mock_context
    ctx.extend(Pangea::Kubernetes::Architecture)
    ctx
  end

  # Build a mock NetworkResult with subnets and vpc
  let(:external_network) do
    network = Pangea::Contracts::NetworkResult.new
    network.vpc = MockResourceRef.new('aws_vpc', :external_vpc)
    network.add_subnet(:public_0, MockResourceRef.new('aws_subnet', :pub_0), tier: :public)
    network.add_subnet(:public_1, MockResourceRef.new('aws_subnet', :pub_1), tier: :public)
    network.add_subnet(:web_0, MockResourceRef.new('aws_subnet', :web_0), tier: :web)
    network.add_subnet(:web_1, MockResourceRef.new('aws_subnet', :web_1), tier: :web)
    network
  end

  let(:base_attrs) do
    {
      backend: :hcloud,
      kubernetes_version: '1.34',
      region: 'nbg1',
      distribution: :k3s,
      profile: 'cilium-standard',
      node_pools: [
        { name: :system, instance_types: ['cx41'], min_size: 1, max_size: 3, ssh_keys: ['my-key'] }
      ],
    }
  end

  it 'uses external_network when provided, skipping create_network' do
    attrs = base_attrs.merge(
      external_network: external_network,
      network: { vpc_cidr: '10.0.0.0/16' }
    )
    result = synth.kubernetes_cluster(:test, attrs)

    # Should use the external network, not create a new one
    expect(result.network).to equal(external_network)
    expect(result.network.vpc.id).to eq('${aws_vpc.external_vpc.id}')
  end

  it 'uses external_network even when network config is nil' do
    attrs = base_attrs.merge(external_network: external_network)
    result = synth.kubernetes_cluster(:test, attrs)
    expect(result.network).to equal(external_network)
  end

  it 'falls back to create_network when external_network is nil' do
    attrs = base_attrs.merge(network: { vpc_cidr: '10.0.0.0/16' })
    result = synth.kubernetes_cluster(:test, attrs)

    # Network should be created by the backend, not the external one
    expect(result.network).not_to be_nil
    expect(result.network).not_to equal(external_network)
  end

  it 'has nil network when both external_network and network are nil' do
    result = synth.kubernetes_cluster(:test, base_attrs)
    expect(result.network).to be_nil
  end

  it 'preserves subnet tiers from external network' do
    attrs = base_attrs.merge(external_network: external_network)
    result = synth.kubernetes_cluster(:test, attrs)

    expect(result.network.public_subnet_ids.length).to eq(2)
    expect(result.network.web_subnet_ids.length).to eq(2)
  end
end
