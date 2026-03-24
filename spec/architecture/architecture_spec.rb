# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Architecture do
  include SynthesisTestHelpers

  # Create a test class that includes the Architecture module
  let(:synth) do
    ctx = create_mock_context
    ctx.extend(described_class)
    ctx
  end

  let(:base_cluster_attrs) do
    {
      backend: :hcloud,
      kubernetes_version: '1.34',
      region: 'nbg1',
      distribution: :k3s,
      profile: 'cilium-standard',
      node_pools: [
        { name: :system, instance_types: ['cx41'], min_size: 1, max_size: 3, ssh_keys: ['my-key'] }
      ],
      network: { vpc_cidr: '10.0.0.0/16' }
    }
  end

  describe '#kubernetes_cluster' do
    it 'returns an ArchitectureResult' do
      result = synth.kubernetes_cluster(:test, base_cluster_attrs)
      expect(result).to be_a(Pangea::Kubernetes::Architecture::ArchitectureResult)
    end

    it 'sets the name on the result' do
      result = synth.kubernetes_cluster(:production, base_cluster_attrs)
      expect(result.name).to eq(:production)
    end

    it 'stores the config on the result' do
      result = synth.kubernetes_cluster(:test, base_cluster_attrs)
      expect(result.config).to be_a(Pangea::Kubernetes::Types::ClusterConfig)
      expect(result.config.backend).to eq(:hcloud)
    end

    it 'creates network resources when network config provided' do
      result = synth.kubernetes_cluster(:test, base_cluster_attrs)
      expect(result.network).not_to be_nil
    end

    it 'skips network creation when network not provided' do
      attrs = base_cluster_attrs.dup
      attrs.delete(:network)
      result = synth.kubernetes_cluster(:test, attrs)
      expect(result.network).to be_nil
    end

    it 'creates IAM resources' do
      result = synth.kubernetes_cluster(:test, base_cluster_attrs)
      expect(result.iam).to be_a(Pangea::Contracts::IamResult)
    end

    it 'creates the cluster' do
      result = synth.kubernetes_cluster(:test, base_cluster_attrs)
      expect(result.cluster).not_to be_nil
    end

    it 'creates node pools for each pool in config' do
      multi_pool_attrs = base_cluster_attrs.merge(
        node_pools: [
          { name: :system, instance_types: ['cx41'], min_size: 1, max_size: 3 },
          { name: :workers, instance_types: ['cx51'], min_size: 2, max_size: 10 }
        ]
      )
      result = synth.kubernetes_cluster(:test, multi_pool_attrs)
      expect(result.node_pools.size).to eq(2)
      expect(result.node_pools).to have_key(:system)
      expect(result.node_pools).to have_key(:workers)
    end

    it 'includes base tags with cluster name and backend' do
      synth.kubernetes_cluster(:mycluster, base_cluster_attrs)
      # Verify that hcloud_firewall was created with proper tags
      firewall = synth.find_resource(:hcloud_firewall, :mycluster_firewall)
      expect(firewall).not_to be_nil
      labels = firewall[:attrs][:labels]
      expect(labels).to include('kubernetescluster' => 'mycluster')
      expect(labels).to include('managedby' => 'Pangea')
    end

    it 'merges custom tags from config' do
      attrs = base_cluster_attrs.merge(tags: { Environment: 'production' })
      synth.kubernetes_cluster(:test, attrs)
      firewall = synth.find_resource(:hcloud_firewall, :test_firewall)
      labels = firewall[:attrs][:labels]
      expect(labels).to include('environment' => 'production')
    end

    context 'with AWS EKS backend' do
      let(:aws_attrs) do
        {
          backend: :aws,
          kubernetes_version: '1.29',
          region: 'us-east-1',
          node_pools: [
            { name: :system, instance_types: ['t3.large'], min_size: 2, max_size: 5 }
          ],
          network: { vpc_cidr: '10.0.0.0/16' }
        }
      end

      it 'creates a complete EKS architecture' do
        result = synth.kubernetes_cluster(:prod, aws_attrs)
        expect(result.cluster.type).to eq('aws_eks_cluster')
        expect(result.network).to have_key(:vpc)
        expect(result.iam).to have_key(:node_role)
      end
    end

    context 'with GCP GKE backend' do
      let(:gcp_attrs) do
        {
          backend: :gcp,
          kubernetes_version: '1.29',
          region: 'us-central1',
          project: 'my-project',
          node_pools: [
            { name: :system, instance_types: ['e2-standard-4'], min_size: 1, max_size: 3 }
          ],
          network: { vpc_cidr: '10.0.0.0/20' }
        }
      end

      it 'creates a complete GKE architecture' do
        result = synth.kubernetes_cluster(:prod, gcp_attrs)
        expect(result.cluster.type).to eq('google_container_cluster')
        expect(result.network).to have_key(:vpc)
        expect(result.iam).to have_key(:node_sa)
      end
    end

    context 'with Azure AKS backend' do
      let(:azure_attrs) do
        {
          backend: :azure,
          kubernetes_version: '1.29',
          region: 'eastus',
          node_pools: [
            { name: :system, instance_types: ['Standard_D4s_v3'], min_size: 1, max_size: 3 }
          ],
          network: { vpc_cidr: '10.0.0.0/16' }
        }
      end

      it 'creates a complete AKS architecture' do
        result = synth.kubernetes_cluster(:prod, azure_attrs)
        expect(result.cluster.type).to eq('azurerm_kubernetes_cluster')
        expect(result.network).to have_key(:resource_group)
      end
    end

    context 'with FluxCD configuration' do
      it 'passes fluxcd config through to cluster creation' do
        attrs = base_cluster_attrs.merge(
          fluxcd: {
            source_url: 'ssh://git@github.com/org/k8s.git',
            reconcile_path: 'clusters/prod'
          }
        )
        result = synth.kubernetes_cluster(:test, attrs)
        expect(result.config.fluxcd).not_to be_nil
        expect(result.config.fluxcd.source_url).to eq('ssh://git@github.com/org/k8s.git')
      end
    end

    context 'VPN config validation' do
      it 'accepts a cloud-init passthrough VPN hash (no :links key)' do
        attrs = base_cluster_attrs.merge(
          vpn: {
            interface: 'wg0',
            address: '10.100.3.2/24',
            port: 51822,
            peer_public_key: 'abc',
            private_key: 'xyz',
          }
        )
        result = synth.kubernetes_cluster(:test, attrs)
        expect(result).to be_a(Pangea::Kubernetes::Architecture::ArchitectureResult)
      end

      it 'accepts a valid VpnConfig hash with links' do
        attrs = base_cluster_attrs.merge(
          vpn: {
            links: [
              {
                name: 'wg0',
                address: '10.100.0.1/24',
                listen_port: 51820,
                peers: [
                  {
                    public_key: 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=',
                    allowed_ips: ['10.0.0.0/24'],
                  }
                ]
              }
            ]
          }
        )
        result = synth.kubernetes_cluster(:test, attrs)
        expect(result.config.vpn).not_to be_nil
        expect(result.config.vpn.links.length).to eq(1)
      end

      it 'accepts nil vpn config' do
        attrs = base_cluster_attrs.dup
        attrs.delete(:vpn)
        result = synth.kubernetes_cluster(:test, attrs)
        expect(result.config.vpn).to be_nil
      end

      it 'accepts an already-constructed VpnConfig' do
        vpn = Pangea::Kubernetes::Types::VpnConfig.new(
          links: [
            {
              name: 'wg0',
              address: '10.100.0.1/24',
              listen_port: 51820,
              peers: [
                {
                  public_key: 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=',
                  allowed_ips: ['10.0.0.0/24'],
                }
              ]
            }
          ]
        )
        attrs = base_cluster_attrs.merge(vpn: vpn)
        result = synth.kubernetes_cluster(:test, attrs)
        expect(result.config.vpn).not_to be_nil
        expect(result.config.vpn.links.length).to eq(1)
      end
    end
  end

  describe '#kubernetes_node_pool' do
    let(:cluster_ref) { MockResourceRef.new('hcloud_server', :test_cp_0) }

    it 'creates a standalone node pool' do
      ref = synth.kubernetes_node_pool(
        :test, :extra_workers,
        { instance_types: ['cx51'], min_size: 2, max_size: 10 },
        cluster_ref: cluster_ref,
        backend: :hcloud
      )
      expect(ref).not_to be_nil
    end

    it 'resolves the correct backend module' do
      synth.kubernetes_node_pool(
        :test, :extra_workers,
        { instance_types: ['cx51'], min_size: 1, max_size: 5 },
        cluster_ref: cluster_ref,
        backend: :hcloud
      )
      # Should have created hcloud_server resources for worker nodes
      workers = synth.created_resources.select { |r| r[:type] == 'hcloud_server' }
      expect(workers.size).to be >= 1
    end

    it 'applies base tags with cluster name and backend' do
      synth.kubernetes_node_pool(
        :mycluster, :workers,
        { instance_types: ['cx51'], min_size: 1, max_size: 5 },
        cluster_ref: cluster_ref,
        backend: :hcloud
      )
      worker = synth.find_resource(:hcloud_server, :mycluster_workers_0)
      expect(worker).not_to be_nil
      labels = worker[:attrs][:labels]
      expect(labels).to include('kubernetescluster' => 'mycluster')
      expect(labels).to include('managedby' => 'Pangea')
    end

    it 'merges custom tags' do
      synth.kubernetes_node_pool(
        :test, :workers,
        { instance_types: ['cx51'], min_size: 1, max_size: 5 },
        cluster_ref: cluster_ref,
        backend: :hcloud,
        tags: { Environment: 'staging' }
      )
      worker = synth.find_resource(:hcloud_server, :test_workers_0)
      labels = worker[:attrs][:labels]
      expect(labels).to include('environment' => 'staging')
    end

    it 'sets the correct pool name from arguments' do
      synth.kubernetes_node_pool(
        :test, :gpu_nodes,
        { instance_types: ['cx51'], min_size: 1, max_size: 5 },
        cluster_ref: cluster_ref,
        backend: :hcloud
      )
      gpu_worker = synth.find_resource(:hcloud_server, :test_gpu_nodes_0)
      expect(gpu_worker).not_to be_nil
    end

    context 'with AWS backend' do
      let(:aws_cluster_ref) { MockResourceRef.new('aws_instance', :prod_cp_0) }

      it 'creates AWS launch template and ASG' do
        synth.kubernetes_node_pool(
          :prod, :workers,
          { instance_types: ['c5.xlarge'], min_size: 2, max_size: 10 },
          cluster_ref: aws_cluster_ref,
          backend: :aws_nixos
        )
        lt = synth.find_resource(:aws_launch_template, :prod_workers_lt)
        asg = synth.find_resource(:aws_autoscaling_group, :prod_workers_asg)
        expect(lt).not_to be_nil
        expect(asg).not_to be_nil
      end
    end
  end

  describe Pangea::Kubernetes::Architecture::ArchitectureResult do
    let(:config) do
      Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :hcloud,
        region: 'nbg1',
        node_pools: [{ name: :system, instance_types: ['cx41'] }]
      )
    end
    let(:result) { described_class.new(:test, config) }

    describe '#initialize' do
      it 'sets name' do
        expect(result.name).to eq(:test)
      end

      it 'sets config' do
        expect(result.config).to eq(config)
      end

      it 'initializes cluster to nil' do
        expect(result.cluster).to be_nil
      end

      it 'initializes network to nil' do
        expect(result.network).to be_nil
      end

      it 'initializes iam to nil' do
        expect(result.iam).to be_nil
      end

      it 'initializes node_pools to empty hash' do
        expect(result.node_pools).to eq({})
      end
    end

    describe '#add_node_pool' do
      it 'adds a node pool by name' do
        ref = MockResourceRef.new('hcloud_server', :test_workers_0)
        result.add_node_pool(:workers, ref)
        expect(result.node_pools[:workers]).to eq(ref)
      end

      it 'converts string names to symbols' do
        ref = MockResourceRef.new('hcloud_server', :test_gpu_0)
        result.add_node_pool('gpu', ref)
        expect(result.node_pools[:gpu]).to eq(ref)
      end
    end

    describe '#method_missing delegation to cluster' do
      it 'delegates unknown methods to cluster' do
        cluster_ref = MockResourceRef.new('hcloud_server', :test_cp_0, { name: 'test-cp-0' })
        result.cluster = cluster_ref
        expect(result.name).to eq(:test) # name is defined on result, not delegated
        expect(result.id).to eq(cluster_ref.id)
      end

      it 'raises NoMethodError when cluster is nil and method unknown' do
        expect { result.nonexistent_method }.to raise_error(NoMethodError)
      end

      it 'raises NoMethodError when cluster does not respond to method' do
        # MockResourceRef responds to everything via method_missing,
        # so we use a simple object instead
        simple_cluster = Object.new
        result.cluster = simple_cluster
        expect { result.totally_nonexistent_xyz }.to raise_error(NoMethodError)
      end
    end

    describe '#respond_to_missing?' do
      it 'returns true for methods the cluster responds to' do
        cluster_ref = MockResourceRef.new('hcloud_server', :test_cp_0)
        result.cluster = cluster_ref
        expect(result.respond_to?(:id)).to be true
        expect(result.respond_to?(:endpoint)).to be true
      end

      it 'returns false when cluster is nil and method not on result' do
        expect(result.respond_to?(:nonexistent_method)).to be false
      end
    end

    describe '#to_h' do
      it 'serializes basic fields' do
        hash = result.to_h
        expect(hash[:name]).to eq(:test)
        expect(hash[:backend]).to eq(:hcloud)
        expect(hash[:kubernetes_version]).to eq('1.29')
        expect(hash[:region]).to eq('nbg1')
        expect(hash[:managed_kubernetes]).to be false
      end

      it 'includes cluster when set' do
        cluster_ref = MockResourceRef.new('hcloud_server', :test_cp_0)
        result.cluster = cluster_ref
        hash = result.to_h
        expect(hash[:cluster]).to be_a(Hash)
      end

      it 'includes nil for cluster when not set' do
        hash = result.to_h
        expect(hash[:cluster]).to be_nil
      end

      it 'includes network as hash when network is a Hash' do
        result.network = {
          vpc: MockResourceRef.new('hcloud_network', :test_network),
          subnet: MockResourceRef.new('hcloud_network_subnet', :test_subnet)
        }
        hash = result.to_h
        expect(hash[:network]).to be_a(Hash)
        expect(hash[:network][:vpc]).to be_a(Hash)
      end

      it 'includes network to_h when network responds to to_h' do
        network_ref = MockResourceRef.new('hcloud_network', :test_network)
        result.network = network_ref
        hash = result.to_h
        expect(hash[:network]).to be_a(Hash)
      end

      it 'returns nil for network when not set' do
        hash = result.to_h
        expect(hash[:network]).to be_nil
      end

      it 'includes iam as hash when iam is a Hash' do
        result.iam = {
          cluster_role: MockResourceRef.new('aws_iam_role', :test_role)
        }
        hash = result.to_h
        expect(hash[:iam]).to be_a(Hash)
        expect(hash[:iam][:cluster_role]).to be_a(Hash)
      end

      it 'includes iam to_h when iam responds to to_h' do
        iam_ref = MockResourceRef.new('aws_iam_role', :test_role)
        result.iam = iam_ref
        hash = result.to_h
        expect(hash[:iam]).to be_a(Hash)
      end

      it 'returns nil for iam when not set' do
        hash = result.to_h
        expect(hash[:iam]).to be_nil
      end

      it 'includes node_pools serialized' do
        result.add_node_pool(:workers, MockResourceRef.new('hcloud_server', :test_workers_0))
        hash = result.to_h
        expect(hash[:node_pools]).to be_a(Hash)
        expect(hash[:node_pools][:workers]).to be_a(Hash)
      end

      it 'handles node pool values without to_h' do
        result.add_node_pool(:workers, 'simple-string')
        hash = result.to_h
        expect(hash[:node_pools][:workers]).to eq('simple-string')
      end
    end
  end
end
