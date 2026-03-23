# frozen_string_literal: true

RSpec.describe 'AWS NixOS kubernetes distribution' do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'test', Backend: 'aws_nixos', ManagedBy: 'Pangea' } }

  describe 'vanilla kubernetes security group rules' do
    it 'includes controller-manager and scheduler ports for kubernetes distribution' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        kubernetes_version: '1.34',
        region: 'us-east-1',
        distribution: :kubernetes,
        profile: 'calico-standard',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        network: { vpc_cidr: '10.0.0.0/16' }
      )

      Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      sg = ctx.find_resource(:aws_security_group, :test_sg)
      rules = sg[:attrs][:ingress]
      cm_rule = rules.find { |r| r[:description] == 'controller-manager' }
      sched_rule = rules.find { |r| r[:description] == 'scheduler' }
      expect(cm_rule).not_to be_nil
      expect(cm_rule[:from_port]).to eq(10257)
      expect(sched_rule).not_to be_nil
      expect(sched_rule[:from_port]).to eq(10259)
    end

    it 'excludes controller-manager and scheduler for k3s distribution' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        kubernetes_version: '1.34',
        region: 'us-east-1',
        distribution: :k3s,
        profile: 'cilium-standard',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        network: { vpc_cidr: '10.0.0.0/16' }
      )

      Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      sg = ctx.find_resource(:aws_security_group, :test_sg)
      rules = sg[:attrs][:ingress]
      cm_rule = rules.find { |r| r[:description] == 'controller-manager' }
      sched_rule = rules.find { |r| r[:description] == 'scheduler' }
      expect(cm_rule).to be_nil
      expect(sched_rule).to be_nil
    end
  end

  describe 'subnet_id resolution for cluster' do
    it 'uses explicit subnet_ids when provided' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        kubernetes_version: '1.34',
        region: 'us-east-1',
        distribution: :k3s,
        profile: 'cilium-standard',
        node_pools: [{ name: :system, instance_types: ['t3.large'], min_size: 1, max_size: 1 }],
        network: { subnet_ids: ['subnet-explicit-1'], vpc_cidr: '10.0.0.0/16' },
        tags: { account_id: '123456789012' }
      )

      arch_result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      arch_result.network = Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      arch_result.iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, config, base_tags)

      ref = Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :test, config, arch_result, base_tags)
      asg = ctx.find_resource(:aws_autoscaling_group, :test_cp_asg)
      expect(asg[:attrs][:vpc_zone_identifier]).to include('subnet-explicit-1')
    end
  end

  describe 'NixOS AMI resolution' do
    it 'uses nixos image_id from nixos config when no ami_id' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        kubernetes_version: '1.34',
        region: 'us-east-1',
        distribution: :k3s,
        profile: 'cilium-standard',
        node_pools: [{ name: :system, instance_types: ['t3.large'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        nixos: { image_id: 'ami-nixos-from-config' },
        tags: { account_id: '123456789012' }
      )

      arch_result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      arch_result.network = Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      arch_result.iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :test, config, arch_result, base_tags)
      lt = ctx.find_resource(:aws_launch_template, :test_cp_lt)
      expect(lt[:attrs][:image_id]).to eq('ami-nixos-from-config')
    end

    it 'falls back to ami-nixos-latest when no ami_id or nixos config' do
      config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos,
        kubernetes_version: '1.34',
        region: 'us-east-1',
        distribution: :k3s,
        profile: 'cilium-standard',
        node_pools: [{ name: :system, instance_types: ['t3.large'], min_size: 1, max_size: 1 }],
        network: { vpc_cidr: '10.0.0.0/16' },
        tags: { account_id: '123456789012' }
      )

      arch_result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, config)
      arch_result.network = Pangea::Kubernetes::Backends::AwsNixos.create_network(ctx, :test, config, base_tags)
      arch_result.iam = Pangea::Kubernetes::Backends::AwsNixos.create_iam(ctx, :test, config, base_tags)

      Pangea::Kubernetes::Backends::AwsNixos.create_cluster(ctx, :test, config, arch_result, base_tags)
      lt = ctx.find_resource(:aws_launch_template, :test_cp_lt)
      expect(lt[:attrs][:image_id]).to eq('ami-nixos-latest')
    end
  end
end
