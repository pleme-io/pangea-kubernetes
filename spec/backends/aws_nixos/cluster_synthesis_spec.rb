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
      account_id: '123456789012',
      etcd_backup_bucket: 'production-etcd-backups',
      ssh_cidr: '10.0.0.0/8',
      api_cidr: '10.0.0.0/8',
      node_pools: [
        { name: :system, instance_types: ['t3.large'], min_size: 3, max_size: 3 },
        { name: :workers, instance_types: ['c5.xlarge'], min_size: 2, max_size: 20 }
      ],
      network: { vpc_cidr: '10.0.0.0/16' },
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
      expect(result).to have_key(:public_a)
      expect(result).to have_key(:web_a)
      expect(result).to have_key(:data_a)
      expect(result).to have_key(:sg)
    end

    it 'creates separate security group rules for K8s ports' do
      described_class.create_network(ctx, :production, cluster_config, base_tags)
      sg_rules = ctx.created_resources.select { |r| r[:type] == 'aws_security_group_rule' && r[:attrs][:type] == 'ingress' }
      api_rule = sg_rules.find { |r| r[:attrs][:description] == 'K8s API' }
      expect(api_rule[:attrs][:from_port]).to eq(6443)
    end

    it 'creates a default route via aws_route resource' do
      described_class.create_network(ctx, :production, cluster_config, base_tags)
      route = ctx.find_resource(:aws_route, :production_public_default_route)
      expect(route).not_to be_nil
      expect(route[:attrs][:destination_cidr_block]).to eq('0.0.0.0/0')
    end

    it 'creates egress rule allowing all outbound' do
      described_class.create_network(ctx, :production, cluster_config, base_tags)
      egress = ctx.find_resource(:aws_security_group_rule, :production_sg_egress_all)
      expect(egress).not_to be_nil
      expect(egress[:attrs][:type]).to eq('egress')
      expect(egress[:attrs][:protocol]).to eq('-1')
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

    it 'passes assume_role_policy as JSON string' do
      iam_result
      roles = ctx.created_resources.select { |r| r[:type] == 'aws_iam_role' }
      role = roles.first
      expect(role[:attrs][:assume_role_policy]).to be_a(String)
      parsed = JSON.parse(role[:attrs][:assume_role_policy])
      expect(parsed['Statement'].first['Principal']['Service']).to eq('ec2.amazonaws.com')
    end

    it 'passes policy documents as JSON strings' do
      iam_result
      policies = ctx.created_resources.select { |r| r[:type] == 'aws_iam_policy' }
      policies.each do |p|
        expect(p[:attrs][:policy]).to be_a(String)
        expect { JSON.parse(p[:attrs][:policy]) }.not_to raise_error
      end
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

    it 'creates LT + ASG + NLB for control plane (not EC2 instances or EKS)' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      expect(ctx.find_resource(:aws_launch_template, :production_cp_lt)).not_to be_nil
      expect(ctx.find_resource(:aws_autoscaling_group, :production_cp_asg)).not_to be_nil
      expect(ctx.find_resource(:aws_lb, :production_cp_nlb)).not_to be_nil
      expect(ctx.find_resource(:aws_lb_target_group, :production_cp_tg)).not_to be_nil
      expect(ctx.find_resource(:aws_lb_listener, :production_cp_listener)).not_to be_nil
      expect(ctx.find_resource(:aws_autoscaling_attachment, :production_cp_asg_tg)).not_to be_nil

      instances = ctx.created_resources.select { |r| r[:type] == 'aws_instance' }
      expect(instances).to be_empty
      expect(ctx.find_resource(:aws_eks_cluster, :production_cluster)).to be_nil
    end

    it 'uses NixOS AMI in launch template (flat attributes)' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_cp_lt)
      expect(lt[:attrs][:image_id]).to eq('ami-nixos-test')
    end

    it 'includes cloud-init with k3s distribution config' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_cp_lt)
      user_data = lt[:attrs][:user_data]
      expect(user_data).to include('"distribution":"k3s"')
      expect(user_data).to include('"profile":"cilium-standard"')
      expect(user_data).to include('"cluster_init":true')
    end

    it 'enforces IMDSv2 on control plane launch template' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_cp_lt)
      metadata = lt[:attrs][:metadata_options]
      expect(metadata[:http_tokens]).to eq('required')
      expect(metadata[:http_put_response_hop_limit]).to eq(1)
    end

    it 'encrypts root volumes via launch template' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_cp_lt)
      ebs = lt[:attrs][:block_device_mappings].first[:ebs]
      expect(ebs[:encrypted]).to be true
    end

    it 'creates internal NLB' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      nlb = ctx.find_resource(:aws_lb, :production_cp_nlb)
      expect(nlb[:attrs][:internal]).to be true
      expect(nlb[:attrs][:load_balancer_type]).to eq('network')
    end

    it 'creates NLB listener on TCP 6443' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      listener = ctx.find_resource(:aws_lb_listener, :production_cp_listener)
      expect(listener[:attrs][:port]).to eq(6443)
      expect(listener[:attrs][:protocol]).to eq('TCP')
    end

    it 'returns a ControlPlaneRef with ipv4_address delegating to NLB dns_name' do
      ref = described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      expect(ref).to be_a(Pangea::Kubernetes::Backends::AwsNixos::ControlPlaneRef)
      expect(ref.ipv4_address).to eq(ref.nlb.dns_name)
    end

    it 'sets CP ASG min_size from system pool min_size' do
      # cluster_config has min_size: 3
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      asg = ctx.find_resource(:aws_autoscaling_group, :production_cp_asg)
      expect(asg[:attrs][:min_size]).to eq(3)
      expect(asg[:attrs][:max_size]).to be >= 3
    end

    it 'NLB listener forwards to target group' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      listener = ctx.find_resource(:aws_lb_listener, :production_cp_listener)
      action = listener[:attrs][:default_action].first
      expect(action[:type]).to eq('forward')
      expect(action[:target_group_arn]).not_to be_nil
    end

    it 'ASG attachment references correct ASG and target group' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      attachment = ctx.find_resource(:aws_autoscaling_attachment, :production_cp_asg_tg)
      expect(attachment[:attrs][:autoscaling_group_name]).not_to be_nil
      expect(attachment[:attrs][:lb_target_group_arn]).not_to be_nil
    end

    it 'adds resource-level tags to launch template' do
      described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_cp_lt)
      expect(lt[:attrs][:tags]).to include(Name: 'production-cp-lt')
    end

    it 'supports vanilla kubernetes distribution' do
      k8s_config = Pangea::Kubernetes::Types::ClusterConfig.new(
        backend: :aws_nixos, kubernetes_version: '1.34', region: 'us-east-1',
        distribution: :kubernetes, profile: 'calico-standard',
        node_pools: [{ name: :system, instance_types: ['t3.large'] }],
        network: { vpc_cidr: '10.0.0.0/16' },
        account_id: '123456789012'
      )

      result = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:test, k8s_config)
      result.network = described_class.create_network(ctx, :test, k8s_config, base_tags)
      result.iam = described_class.create_iam(ctx, :test, k8s_config, base_tags)

      described_class.create_cluster(ctx, :test, k8s_config, result, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :test_cp_lt)
      user_data = lt[:attrs][:user_data]
      expect(user_data).to include('"distribution":"kubernetes"')
      expect(user_data).to include('"profile":"calico-standard"')
      expect(user_data).to include('"role":"control-plane"')
    end

    context 'parked mode (min_size=0)' do
      let(:parked_config) do
        Pangea::Kubernetes::Types::ClusterConfig.new(
          backend: :aws_nixos, kubernetes_version: '1.34', region: 'us-east-1',
          distribution: :k3s, profile: 'cilium-standard', distribution_track: '1.34',
          ami_id: 'ami-nixos-test', key_pair: 'my-key',
          node_pools: [
            { name: :system, instance_types: ['t3.small'], min_size: 0, max_size: 1 },
          ],
          network: { vpc_cidr: '10.0.0.0/16' },
          account_id: '123456789012', etcd_backup_bucket: 'test-etcd'
        )
      end
      let(:parked_arch) do
        r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:parked, parked_config)
        r.network = described_class.create_network(ctx, :parked, parked_config, base_tags)
        r.iam = described_class.create_iam(ctx, :parked, parked_config, base_tags)
        r
      end

      it 'sets CP ASG min_size to 0' do
        described_class.create_cluster(ctx, :parked, parked_config, parked_arch, base_tags)
        asg = ctx.find_resource(:aws_autoscaling_group, :parked_cp_asg)
        expect(asg[:attrs][:min_size]).to eq(0)
      end

      it 'still creates LT, NLB, and all infra' do
        described_class.create_cluster(ctx, :parked, parked_config, parked_arch, base_tags)
        expect(ctx.find_resource(:aws_launch_template, :parked_cp_lt)).not_to be_nil
        expect(ctx.find_resource(:aws_lb, :parked_cp_nlb)).not_to be_nil
        expect(ctx.find_resource(:aws_lb_target_group, :parked_cp_tg)).not_to be_nil
      end
    end

    context 'with karpenter_enabled' do
      let(:karpenter_config) do
        Pangea::Kubernetes::Types::ClusterConfig.new(
          backend: :aws_nixos, kubernetes_version: '1.34', region: 'us-east-1',
          distribution: :k3s, profile: 'cilium-standard', distribution_track: '1.34',
          ami_id: 'ami-nixos-test', key_pair: 'my-key', karpenter_enabled: true,
          node_pools: [{ name: :system, instance_types: ['t3.small'], min_size: 1, max_size: 1 }],
          network: { vpc_cidr: '10.0.0.0/16' },
          account_id: '123456789012', etcd_backup_bucket: 'test-etcd'
        )
      end

      it 'creates Karpenter IAM role and instance profile' do
        iam = described_class.create_iam(ctx, :karp, karpenter_config, base_tags)
        expect(iam[:karpenter_role]).not_to be_nil
        expect(iam[:karpenter_profile]).not_to be_nil
      end
    end

    context 'without karpenter_enabled' do
      it 'does not create Karpenter IAM resources' do
        iam = described_class.create_iam(ctx, :production, cluster_config, base_tags)
        expect(iam).not_to have_key(:karpenter_role)
        expect(iam).not_to have_key(:karpenter_profile)
      end
    end

    context 'with argocd gitops operator' do
      let(:argocd_config) do
        Pangea::Kubernetes::Types::ClusterConfig.new(
          backend: :aws_nixos, kubernetes_version: '1.34', region: 'us-east-1',
          distribution: :k3s, profile: 'cilium-standard', distribution_track: '1.34',
          ami_id: 'ami-nixos-test', key_pair: 'my-key',
          gitops_operator: :argocd,
          argocd: { repo_url: 'ssh://git@github.com/pleme-io/akeyless-k8s', path: './clusters/kazoku' },
          node_pools: [{ name: :system, instance_types: ['t3.small'], min_size: 1, max_size: 1 }],
          network: { vpc_cidr: '10.0.0.0/16' },
          account_id: '123456789012', etcd_backup_bucket: 'test-etcd'
        )
      end
      let(:argocd_arch) do
        r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:argo, argocd_config)
        r.network = described_class.create_network(ctx, :argo, argocd_config, base_tags)
        r.iam = described_class.create_iam(ctx, :argo, argocd_config, base_tags)
        r
      end

      it 'includes argocd config in cloud-init (not fluxcd)' do
        described_class.create_cluster(ctx, :argo, argocd_config, argocd_arch, base_tags)
        lt = ctx.find_resource(:aws_launch_template, :argo_cp_lt)
        user_data = lt[:attrs][:user_data]
        expect(user_data).to include('"argocd"')
        expect(user_data).to include('pleme-io/akeyless-k8s')
        expect(user_data).not_to include('"fluxcd"')
      end
    end
  end

  describe '.create_node_pool' do
    let(:network_result) { described_class.create_network(ctx, :production, cluster_config, base_tags) }
    let(:iam_result) { described_class.create_iam(ctx, :production, cluster_config, base_tags) }
    let(:arch_result) do
      r = Pangea::Kubernetes::Architecture::ArchitectureResult.new(:production, cluster_config)
      r.network = network_result
      r.iam = iam_result
      r
    end
    let(:cluster_ref) { described_class.create_cluster(ctx, :production, cluster_config, arch_result, base_tags) }
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

    it 'includes IAM instance profile on worker launch template' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_workers_lt)
      expect(lt[:attrs][:iam_instance_profile]).not_to be_nil
    end

    it 'includes security group on worker launch template' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_workers_lt)
      expect(lt[:attrs][:vpc_security_group_ids]).not_to be_empty
    end

    it 'worker cloud-init includes join_server from NLB' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_workers_lt)
      expect(lt[:attrs][:user_data]).to include('"join_server"')
      expect(lt[:attrs][:user_data]).to include(cluster_ref.ipv4_address.to_s)
    end

    it 'adds resource-level tags to worker launch template' do
      described_class.create_node_pool(ctx, :production, cluster_ref, pool_config, base_tags)

      lt = ctx.find_resource(:aws_launch_template, :production_workers_lt)
      expect(lt[:attrs][:tags]).to include(Name: 'production-workers-lt')
    end
  end
end
