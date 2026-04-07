# frozen_string_literal: true

RSpec.describe 'ClusterConfig helper methods' do
  let(:base_attrs) do
    {
      backend: :aws,
      region: 'us-east-1',
      node_pools: [
        { name: :system, instance_types: ['t3.large'], min_size: 2, max_size: 5 },
        { name: :workers, instance_types: ['c5.xlarge'], min_size: 1, max_size: 10 }
      ]
    }
  end

  describe '#managed_kubernetes?' do
    it 'returns true for aws (EKS)' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(backend: :aws))
      expect(config.managed_kubernetes?).to be true
    end

    it 'returns true for gcp (GKE)' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(backend: :gcp))
      expect(config.managed_kubernetes?).to be true
    end

    it 'returns true for azure (AKS)' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(backend: :azure))
      expect(config.managed_kubernetes?).to be true
    end

    it 'returns false for aws_nixos' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(backend: :aws_nixos))
      expect(config.managed_kubernetes?).to be false
    end

    it 'returns false for hcloud' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(backend: :hcloud))
      expect(config.managed_kubernetes?).to be false
    end
  end

  describe '#nixos_backend?' do
    it 'returns true for aws_nixos' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(backend: :aws_nixos))
      expect(config.nixos_backend?).to be true
    end

    it 'returns true for gcp_nixos' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(backend: :gcp_nixos))
      expect(config.nixos_backend?).to be true
    end

    it 'returns true for azure_nixos' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(backend: :azure_nixos))
      expect(config.nixos_backend?).to be true
    end

    it 'returns true for hcloud' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(backend: :hcloud))
      expect(config.nixos_backend?).to be true
    end

    it 'returns false for managed backends' do
      %i[aws gcp azure].each do |backend|
        config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(backend: backend))
        expect(config.nixos_backend?).to be(false), "Expected #{backend} to not be a NixOS backend"
      end
    end
  end

  describe '#system_node_pool' do
    it 'returns the pool named :system' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      expect(config.system_node_pool.name).to eq(:system)
    end

    it 'falls back to first pool when no :system pool exists' do
      attrs = base_attrs.merge(
        node_pools: [{ name: :primary, instance_types: ['t3.large'] }]
      )
      config = Pangea::Kubernetes::Types::ClusterConfig.new(attrs)
      expect(config.system_node_pool.name).to eq(:primary)
    end
  end

  describe '#worker_node_pools' do
    it 'returns pools excluding :system' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      workers = config.worker_node_pools
      expect(workers.size).to eq(1)
      expect(workers.first.name).to eq(:workers)
    end

    it 'returns empty when only system pool exists' do
      attrs = base_attrs.merge(
        node_pools: [{ name: :system, instance_types: ['t3.large'] }]
      )
      config = Pangea::Kubernetes::Types::ClusterConfig.new(attrs)
      expect(config.worker_node_pools).to be_empty
    end

    it 'returns all pools when no system pool' do
      attrs = base_attrs.merge(
        node_pools: [
          { name: :gpu, instance_types: ['p3.2xlarge'] },
          { name: :compute, instance_types: ['c5.4xlarge'] }
        ]
      )
      config = Pangea::Kubernetes::Types::ClusterConfig.new(attrs)
      expect(config.worker_node_pools.size).to eq(2)
    end
  end

  describe 'gitops_operator validation' do
    it 'accepts :fluxcd' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(gitops_operator: :fluxcd))
      expect(config.gitops_operator).to eq(:fluxcd)
    end

    it 'accepts :argocd' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(gitops_operator: :argocd))
      expect(config.gitops_operator).to eq(:argocd)
    end

    it 'accepts :none' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(gitops_operator: :none))
      expect(config.gitops_operator).to eq(:none)
    end

    it 'defaults to :fluxcd' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs)
      expect(config.gitops_operator).to eq(:fluxcd)
    end

    it 'rejects invalid operator' do
      expect {
        Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs.merge(gitops_operator: :helm))
      }.to raise_error(Dry::Struct::Error)
    end
  end

  describe 'VPN config validation integration' do
    let(:valid_peer) do
      {
        public_key: 'YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXoxMjM0NTY=',
        allowed_ips: ['10.0.0.0/24']
      }
    end

    it 'validates VPN config on construction' do
      expect {
        Pangea::Kubernetes::Types::ClusterConfig.new(
          base_attrs.merge(
            vpn: {
              links: [{
                name: 'wg0',
                address: 'not-valid',
                peers: [valid_peer]
              }]
            }
          )
        )
      }.to raise_error(ArgumentError, /not a valid CIDR/)
    end

    it 'accepts valid VPN config' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        base_attrs.merge(
          vpn: {
            links: [{
              name: 'wg0',
              address: '10.100.0.1/24',
              listen_port: 51820,
              profile: 'k8s-control-plane',
              peers: [valid_peer]
            }]
          }
        )
      )
      expect(config.vpn).not_to be_nil
      expect(config.vpn.links.size).to eq(1)
    end
  end

  describe 'boolean defaults' do
    let(:config) { Pangea::Kubernetes::Types::ClusterConfig.new(base_attrs) }

    it 'defaults encryption_at_rest to true' do
      expect(config.encryption_at_rest).to be true
    end

    it 'defaults karpenter_enabled to false' do
      expect(config.karpenter_enabled).to be false
    end

    it 'defaults etcd_backup_enabled to false' do
      expect(config.etcd_backup_enabled).to be false
    end

    it 'defaults etcd_backup_versioning to false' do
      expect(config.etcd_backup_versioning).to be false
    end

    it 'defaults ingress_alb_enabled to false' do
      expect(config.ingress_alb_enabled).to be false
    end

    it 'defaults vpn_nlb_enabled to false' do
      expect(config.vpn_nlb_enabled).to be false
    end

    it 'defaults sg_restrict_http_to_alb to true' do
      expect(config.sg_restrict_http_to_alb).to be true
    end

    it 'defaults flow_logs_enabled to false' do
      expect(config.flow_logs_enabled).to be false
    end

    it 'defaults kms_logs_enabled to false' do
      expect(config.kms_logs_enabled).to be false
    end

    it 'defaults nat_per_az to false' do
      expect(config.nat_per_az).to be false
    end

    it 'defaults ssm_only to false' do
      expect(config.ssm_only).to be false
    end
  end
end
