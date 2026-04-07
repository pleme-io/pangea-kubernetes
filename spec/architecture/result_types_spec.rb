# frozen_string_literal: true

RSpec.describe 'Architecture result types' do
  describe Pangea::Kubernetes::Architecture::NetworkResult do
    let(:result) { described_class.new }

    it 'is a Pangea::Contracts::NetworkResult' do
      expect(result).to be_a(Pangea::Contracts::NetworkResult)
    end

    describe 'AWS-specific fields' do
      it 'initializes all fields to nil' do
        expect(result.igw).to be_nil
        expect(result.route_table).to be_nil
        expect(result.etcd_bucket).to be_nil
        expect(result.flow_log).to be_nil
        expect(result.flow_log_role).to be_nil
        expect(result.ssm_logs_bucket).to be_nil
        expect(result.kms_key).to be_nil
      end

      it 'allows setting igw' do
        result.igw = 'igw-123'
        expect(result.igw).to eq('igw-123')
      end

      it 'allows setting route_table' do
        result.route_table = 'rtb-123'
        expect(result.route_table).to eq('rtb-123')
      end

      it 'allows setting etcd_bucket' do
        result.etcd_bucket = 's3-bucket'
        expect(result.etcd_bucket).to eq('s3-bucket')
      end
    end

    describe '#[]' do
      it 'accesses igw via hash-style' do
        result.igw = 'igw-abc'
        expect(result[:igw]).to eq('igw-abc')
      end

      it 'accesses route_table via hash-style' do
        result.route_table = 'rtb-abc'
        expect(result[:route_table]).to eq('rtb-abc')
      end

      it 'accesses etcd_bucket via hash-style' do
        result.etcd_bucket = 'bucket'
        expect(result[:etcd_bucket]).to eq('bucket')
      end

      it 'accesses flow_log via hash-style' do
        result.flow_log = 'fl-123'
        expect(result[:flow_log]).to eq('fl-123')
      end

      it 'accesses ssm_logs_bucket via hash-style' do
        result.ssm_logs_bucket = 'ssm-bucket'
        expect(result[:ssm_logs_bucket]).to eq('ssm-bucket')
      end

      it 'accesses kms_key via hash-style' do
        result.kms_key = 'kms-key-123'
        expect(result[:kms_key]).to eq('kms-key-123')
      end

      it 'delegates unknown keys to super' do
        result.vpc = 'vpc-ref'
        expect(result[:vpc]).to eq('vpc-ref')
      end
    end

    describe '#to_h' do
      it 'includes set fields' do
        result.igw = 'igw-123'
        result.etcd_bucket = 'bucket'
        hash = result.to_h
        expect(hash[:igw]).to eq('igw-123')
        expect(hash[:etcd_bucket]).to eq('bucket')
      end

      it 'omits nil fields' do
        hash = result.to_h
        expect(hash).not_to have_key(:igw)
        expect(hash).not_to have_key(:route_table)
        expect(hash).not_to have_key(:etcd_bucket)
      end
    end
  end

  describe Pangea::Kubernetes::Architecture::GcpNetworkResult do
    let(:result) { described_class.new }

    it 'is a Pangea::Contracts::NetworkResult' do
      expect(result).to be_a(Pangea::Contracts::NetworkResult)
    end

    describe '#[]' do
      it 'accesses firewall_internal' do
        result.firewall_internal = 'fw-internal'
        expect(result[:firewall_internal]).to eq('fw-internal')
      end

      it 'accesses firewall_external' do
        result.firewall_external = 'fw-external'
        expect(result[:firewall_external]).to eq('fw-external')
      end
    end

    describe '#to_h' do
      it 'includes firewall fields when set' do
        result.firewall_internal = 'fw-int'
        hash = result.to_h
        expect(hash[:firewall_internal]).to eq('fw-int')
      end

      it 'omits nil firewall fields' do
        hash = result.to_h
        expect(hash).not_to have_key(:firewall_internal)
        expect(hash).not_to have_key(:firewall_external)
      end
    end
  end

  describe Pangea::Kubernetes::Architecture::AzureNetworkResult do
    let(:result) { described_class.new }

    it 'is a Pangea::Contracts::NetworkResult' do
      expect(result).to be_a(Pangea::Contracts::NetworkResult)
    end

    describe '#[]' do
      it 'accesses resource_group' do
        result.resource_group = 'rg-test'
        expect(result[:resource_group]).to eq('rg-test')
      end

      it 'accesses vnet' do
        result.vnet = 'vnet-test'
        expect(result[:vnet]).to eq('vnet-test')
      end

      it 'accesses nsg' do
        result.nsg = 'nsg-test'
        expect(result[:nsg]).to eq('nsg-test')
      end
    end

    describe '#to_h' do
      it 'includes azure fields when set' do
        result.resource_group = 'rg'
        result.vnet = 'vnet'
        result.nsg = 'nsg'
        hash = result.to_h
        expect(hash[:resource_group]).to eq('rg')
        expect(hash[:vnet]).to eq('vnet')
        expect(hash[:nsg]).to eq('nsg')
      end

      it 'omits nil azure fields' do
        hash = result.to_h
        expect(hash).not_to have_key(:resource_group)
        expect(hash).not_to have_key(:vnet)
        expect(hash).not_to have_key(:nsg)
      end
    end
  end

  describe Pangea::Kubernetes::Architecture::HcloudNetworkResult do
    let(:result) { described_class.new }

    it 'is a Pangea::Contracts::NetworkResult' do
      expect(result).to be_a(Pangea::Contracts::NetworkResult)
    end

    describe '#[]' do
      it 'accesses network' do
        result.network = 'hc-net-123'
        expect(result[:network]).to eq('hc-net-123')
      end
    end

    describe '#to_h' do
      it 'includes network when set' do
        result.network = 'hc-net'
        expect(result.to_h[:network]).to eq('hc-net')
      end

      it 'omits network when nil' do
        expect(result.to_h).not_to have_key(:network)
      end
    end
  end

  describe Pangea::Kubernetes::Architecture::IamResult do
    let(:result) { described_class.new }

    it 'is a Pangea::Contracts::IamResult' do
      expect(result).to be_a(Pangea::Contracts::IamResult)
    end

    describe 'AWS-specific IAM fields' do
      it 'initializes all fields to nil' do
        expect(result.log_group).to be_nil
        expect(result.ecr_policy).to be_nil
        expect(result.etcd_policy).to be_nil
        expect(result.logs_policy).to be_nil
        expect(result.ec2_policy).to be_nil
        expect(result.ssm_policy).to be_nil
        expect(result.karpenter_role).to be_nil
        expect(result.karpenter_profile).to be_nil
      end
    end

    describe '#[]' do
      it 'accesses log_group via hash-style' do
        result.log_group = 'lg-123'
        expect(result[:log_group]).to eq('lg-123')
      end

      it 'accesses ecr_policy via hash-style' do
        result.ecr_policy = 'ecr-pol'
        expect(result[:ecr_policy]).to eq('ecr-pol')
      end

      it 'accesses karpenter_role via hash-style' do
        result.karpenter_role = 'karp-role'
        expect(result[:karpenter_role]).to eq('karp-role')
      end

      it 'accesses karpenter_profile via hash-style' do
        result.karpenter_profile = 'karp-prof'
        expect(result[:karpenter_profile]).to eq('karp-prof')
      end
    end

    describe '#to_h' do
      it 'includes set fields' do
        result.log_group = 'lg'
        result.karpenter_role = 'karp'
        hash = result.to_h
        expect(hash[:log_group]).to eq('lg')
        expect(hash[:karpenter_role]).to eq('karp')
      end

      it 'omits nil fields' do
        hash = result.to_h
        expect(hash).not_to have_key(:log_group)
        expect(hash).not_to have_key(:karpenter_role)
      end
    end
  end

  describe Pangea::Kubernetes::Architecture::AwsEksIamResult do
    let(:result) { described_class.new }

    it 'is both IamResult and Pangea::Contracts::IamResult' do
      expect(result).to be_a(Pangea::Kubernetes::Architecture::IamResult)
      expect(result).to be_a(Pangea::Contracts::IamResult)
    end

    describe '#[]' do
      it 'accesses cluster_role via hash-style' do
        result.cluster_role = 'eks-role'
        expect(result[:cluster_role]).to eq('eks-role')
      end

      it 'accesses node_role via hash-style' do
        result.node_role = 'node-role'
        expect(result[:node_role]).to eq('node-role')
      end

      it 'falls back to parent fields' do
        result.log_group = 'lg-eks'
        expect(result[:log_group]).to eq('lg-eks')
      end
    end

    describe '#to_h' do
      it 'includes EKS-specific and parent fields' do
        result.cluster_role = 'eks-role'
        result.log_group = 'lg'
        hash = result.to_h
        expect(hash[:cluster_role]).to eq('eks-role')
        expect(hash[:log_group]).to eq('lg')
      end
    end
  end

  describe Pangea::Kubernetes::Architecture::GcpIamResult do
    let(:result) { described_class.new }

    it 'is a Pangea::Contracts::IamResult' do
      expect(result).to be_a(Pangea::Contracts::IamResult)
    end

    describe '#[]' do
      it 'accesses node_sa via hash-style' do
        result.node_sa = 'sa-gcp'
        expect(result[:node_sa]).to eq('sa-gcp')
      end
    end

    describe '#to_h' do
      it 'includes node_sa when set' do
        result.node_sa = 'gcp-sa'
        expect(result.to_h[:node_sa]).to eq('gcp-sa')
      end

      it 'omits node_sa when nil' do
        expect(result.to_h).not_to have_key(:node_sa)
      end
    end
  end
end
