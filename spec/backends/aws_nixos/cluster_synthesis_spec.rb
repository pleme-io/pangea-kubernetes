# frozen_string_literal: true

RSpec.describe Pangea::Kubernetes::Backends::AwsNixos do
  include SynthesisTestHelpers

  let(:ctx) { create_mock_context }
  let(:base_tags) { { KubernetesCluster: 'production', Backend: 'aws_nixos', ManagedBy: 'Pangea' } }

  let(:cluster_config) do
    Pangea::Kubernetes::Types::ClusterConfig.new(
      backend: :aws_nixos,
      kubernetes_version: '1.34',
      region: 'us-east-1',
      distribution: :k3s,
      profile: 'cilium-standard',
      distribution_track: '1.34',
      ami_id: 'ami-nixos-test',
      key_pair: 'my-key',
      node_pools: [
        { name: :system, instance_types: ['t3.large'], min_size: 3, max_size: 3 },
        { name: :workers, instance_types: ['c5.xlarge'], min_size: 2, max_size: 20 }
      ],
      network: { vpc_cidr: '10.0.0.0/16' },
      tags: {
        account_id: '123456789012',
        etcd_backup_bucket: 'production-etcd-backups',
        ssh_cidr: '10.0.0.0/8',
        api_cidr: '10.0.0.0/8',
      }
    )
  end

  describe '.backend_name' do
    it('returns :aws_nixos') { expect(described_class.backend_name).to eq(:aws_nixos) }
  end

  describe '.managed_kubernetes?' do
    it('returns false') { expect(described_class.managed_kubernetes?).to be false }
  end

  describe '.create_network' do
    it 'creates VPC, IGW, route table, subnets, and security group' do
      result = described_class.create_network(ctx, :production, cluster_config, base_tags)

      expect(result).to have_key(:vpc)
      expect(result).to have_key(:igw)
      expect(result).to have_key(:route_table)
      expect(result).to have_key(:subnet_a)
      expect(result).to have_key(:subnet_b)
      expect(result).to have_key(:sg)
    end

    it 'creates security group with K8s ports' do
      described_class.create_network(ctx, :production, cluster_config, base_tags)
      sg = ctx.find_resource(:aws_security_group, :production_sg)
      expect(sg[:attrs][:ingress]).to be_an(Array)
      api_rule = sg[:attrs][:ingress].find { |r| r[:description] == 'K8s API' }
      expect(api_rule[:from_port]).to eq(6443)
    end

    it 'protects VPC with prevent_destroy' do
      described_class.create_network(ctx, :production, cluster_config, base_tags)
      vpc = ctx.find_resource(:aws_vpc, :production_vpc)
      expect(vpc[:attrs][:lifecycle]).to eq({ prevent_destroy: true })
    end
  end

  describe '.create_iam' do
    let(:iam_result) { described_class.create_iam(ctx, :production, cluster_config, base_tags) }

    it 'creates node role and instance profile' do
      expect(iam_result).to have_key(:role)
      expect(iam_result).to have_key(:instance_profile)
    end

    it 'creates 5 least-privilege IAM policies' do
      expect(iam_result).to have_key(:ecr_policy)
      expect(iam_result).to have_key(:etcd_policy)
      expect(iam_result).to have_key(:logs_policy)
      expect(iam_result).to have_key(:ec2_policy)
      expect(iam_result).to have_key(:ssm_policy)
    end

    it 'creates CloudWatch log group' do
      expect(iam_result).to have_key(:log_group)
    end

    it 'sets max_session_duration to 3600' do
      iam_result # trigger creation
      roles = ctx.created_resources.select { |r| r[:type] == 'aws_iam_role' }
      role = roles.first
      expect(role[:attrs][:max_session_duration]).to eq(3600)
    end

    it 'protects IAM role with prevent_destroy' do
      iam_result
      roles = ctx.created_resources.select { |r| r[:type] == 'aws_iam_role' }
      role = roles.first
      expect(role[:attrs][:lifecycle]).to eq({ prevent_destroy: true })
    end

    it 'tags instance profile' do
      iam_result
      profiles = ctx.created_resources.select { |r| r[:type] == 'aws_iam_instance_profile' }
      ip = profiles.first
      expect(ip[:attrs][:tags]).to include(:Name)
    end
  end

  describe '.create_cluster' do
    let(:network_result) { described_class.create_network(ctx, :production, cluster_config, base_tags) }
    let(:iam_result) { described_class.create_iam(ctx, :production, cluster_config, base_tags) }
    let(:arch_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:production, cluster_config)
      r.network = network_result
      r.iam = iam_result
      r
    end

    it 'creates EC2 instances for control plane (not EKS)' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      instances = ctx.created_resources.select { |r| r[:type] == 'aws_instance' }
      expect(instances.size).to eq(3) # min_size: 3
      expect(ctx.find_resource(:aws_eks_cluster, :production_cluster)).to be_nil
    end

    it 'uses NixOS AMI' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :production_cp_0)
      expect(cp_0[:attrs][:ami]).to eq('ami-nixos-test')
    end

    it 'includes cloud-init with k3s distribution config' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :production_cp_0)
      user_data = cp_0[:attrs][:user_data]
      expect(user_data).to include('"distribution":"k3s"')
      expect(user_data).to include('"profile":"cilium-standard"')
      expect(user_data).to include('"cluster_init":true')
    end

    it 'sets first node as cluster-init, rest as non-init' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :production_cp_0)
      cp_1 = ctx.find_resource(:aws_instance, :production_cp_1)

      expect(cp_0[:attrs][:user_data]).to include('"cluster_init":true')
      expect(cp_1[:attrs][:user_data]).to include('"cluster_init":false')
    end

    it 'enforces IMDSv2 on control plane instances' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :production_cp_0)
      metadata = cp_0[:attrs][:metadata_options]
      expect(metadata[:http_tokens]).to eq('required')
      expect(metadata[:http_put_response_hop_limit]).to eq(1)
    end

    it 'encrypts root volumes' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :production_cp_0)
      expect(cp_0[:attrs][:root_block_device][:encrypted]).to be true
    end

    it 'supports vanilla kubernetes distribution' do
      k8s_config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.34', region: 'us-east-1',
        distribution: :kubernetes, profile: 'calico-standard',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        network: { vpc_cidr: '10.0.0.0/16' }
      )

      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, k8s_config)
      result.network = described_class.create_network(ctx, :test, k8s_config, base_tags)
      result.iam = described_class.create_iam(ctx, :test, k8s_config, base_tags)

      described_class.create_cluster(ctx, :test, k8s_config, result, base_tags)

      cp_0 = ctx.find_resource(:aws_instance, :test_cp_0)
      user_data = cp_0[:attrs][:user_data]
      expect(user_data).to include('"distribution":"kubernetes"')
      expect(user_data).to include('"profile":"calico-standard"')
      expect(user_data).to include('"role":"control-plane"')
    end
  end

  describe '.create_node_pool' do
    let(:cluster_ref) { MockResourceRef.new('aws_instance', :production_cp_0) }
    let(:pool_config) do
      Pangea::Kubernetes::Types::NodePoolConfig.new(
        name: :workers, instance_types: ['c5.xlarge'],
        min_size: 2, max_size: 20, disk_size_gb: 100
      )
    end

    it 'creates Launch Template + ASG (not EKS node group)' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_workers_lt)
      asg = ctx.find_resource(:aws_autoscaling_group, :production_workers_asg)

      expect(lt).not_to be_nil
      expect(asg).not_to be_nil
    end

    it 'sets ASG scaling parameters' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      asg = ctx.find_resource(:aws_autoscaling_group, :production_workers_asg)
      expect(asg[:attrs][:min_size]).to eq(2)
      expect(asg[:attrs][:max_size]).to eq(20)
      expect(asg[:attrs][:desired_capacity]).to eq(2) # effective_desired_size
    end

    it 'includes cloud-init with agent role' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_workers_lt)
      expect(lt[:attrs][:user_data]).to include('"role":"agent"')
    end

    it 'enforces IMDSv2 on worker launch template' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_workers_lt)
      metadata = lt[:attrs][:metadata_options]
      expect(metadata[:http_tokens]).to eq('required')
    end

    it 'encrypts worker volumes' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_workers_lt)
      ebs = lt[:attrs][:block_device_mappings].first[:ebs]
      expect(ebs[:encrypted]).to be true
    end
  end
end
