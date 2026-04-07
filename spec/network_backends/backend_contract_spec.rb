# frozen_string_literal: true

require 'spec_helper'
require 'pangea/kubernetes/network_backends/vpc_cni'
require 'pangea/kubernetes/network_backends/cilium'

RSpec.describe 'Network backend contract enforcement' do
  include SynthesisTestHelpers

  describe Pangea::Kubernetes::NetworkBackends::Base do
    let(:unimplemented_backend) do
      mod = Module.new
      mod.include(described_class)
      mod
    end

    describe '.backend_name' do
      it 'raises NotImplementedError when not overridden' do
        expect { unimplemented_backend.backend_name }.to raise_error(NotImplementedError, /must implement/)
      end
    end

    describe '.compatible_backends' do
      it 'raises NotImplementedError when not overridden' do
        expect { unimplemented_backend.compatible_backends }.to raise_error(NotImplementedError, /must implement/)
      end
    end

    describe '.mesh_capable?' do
      it 'defaults to false' do
        expect(unimplemented_backend.mesh_capable?).to be false
      end
    end

    describe '.l7_observable?' do
      it 'defaults to false' do
        expect(unimplemented_backend.l7_observable?).to be false
      end
    end

    describe '.create_network_iam' do
      it 'defaults to nil' do
        result = unimplemented_backend.create_network_iam(nil, nil, nil, nil)
        expect(result).to be_nil
      end
    end

    describe '.nixos_profile' do
      it 'defaults to nil' do
        expect(unimplemented_backend.nixos_profile).to be_nil
      end
    end

    describe '.helm_values' do
      it 'defaults to empty hash' do
        expect(unimplemented_backend.helm_values({})).to eq({})
      end
    end
  end

  describe Pangea::Kubernetes::NetworkBackends::VpcCni do
    it 'identifies as :vpc_cni' do
      expect(described_class.backend_name).to eq(:vpc_cni)
    end

    it 'is only compatible with :aws' do
      expect(described_class.compatible_backends).to eq([:aws])
    end

    it 'is not mesh capable' do
      expect(described_class.mesh_capable?).to be false
    end

    it 'is not L7 observable' do
      expect(described_class.l7_observable?).to be false
    end

    it 'has no NixOS profile' do
      expect(described_class.nixos_profile).to be_nil
    end
  end

  describe Pangea::Kubernetes::NetworkBackends::Cilium do
    it 'identifies as :cilium' do
      expect(described_class.backend_name).to eq(:cilium)
    end

    it 'is compatible with all major backends' do
      backends = described_class.compatible_backends
      expect(backends).to include(:aws)
      expect(backends).to include(:gcp)
      expect(backends).to include(:azure)
      expect(backends).to include(:hcloud)
      expect(backends).to include(:aws_nixos)
    end

    it 'is mesh capable' do
      expect(described_class.mesh_capable?).to be true
    end

    it 'is L7 observable' do
      expect(described_class.l7_observable?).to be true
    end

    it 'has cilium-mesh NixOS profile' do
      expect(described_class.nixos_profile).to eq('cilium-mesh')
    end

    describe '.helm_values' do
      it 'enables Hubble by default' do
        values = described_class.helm_values({})
        expect(values['hubble']['enabled']).to be true
        expect(values['hubble']['relay']['enabled']).to be true
      end

      it 'disables Hubble UI (MCP-queryable via Grafana)' do
        values = described_class.helm_values({})
        expect(values['hubble']['ui']['enabled']).to be false
      end

      it 'enables Prometheus metrics' do
        values = described_class.helm_values({})
        expect(values['prometheus']['enabled']).to be true
        expect(values['operator']['prometheus']['enabled']).to be true
      end

      it 'enables ENI in default mode' do
        values = described_class.helm_values({})
        expect(values['eni']['enabled']).to be true
        expect(values['eni']['awsEnablePrefixDelegation']).to be true
        expect(values['tunnel']).to eq('disabled')
      end

      it 'skips ENI config in overlay mode' do
        values = described_class.helm_values({ cilium_mode: :overlay })
        expect(values).not_to have_key('eni')
        expect(values).not_to have_key('tunnel')
      end

      it 'sets IPAM mode from config' do
        values = described_class.helm_values({ cilium_mode: :overlay })
        expect(values['ipam']['mode']).to eq('overlay')
      end

      it 'includes httpV2 metrics with exemplars' do
        values = described_class.helm_values({})
        metrics = values['hubble']['metrics']['enabled']
        expect(metrics).to be_an(Array)
        http_v2 = metrics.find { |m| m.include?('httpV2') }
        expect(http_v2).not_to be_nil
        expect(http_v2).to include('exemplars=true')
      end
    end

    describe '.create_network_iam' do
      it 'returns nil for non-AWS compute backends' do
        result = described_class.create_network_iam(nil, :test, { compute_backend: :gcp }, {})
        expect(result).to be_nil
      end

      it 'creates IAM policy for AWS compute backend' do
        ctx = create_mock_context
        result = described_class.create_network_iam(
          ctx, :test, { compute_backend: :aws }, { Environment: 'test' }
        )
        expect(result).to be_a(Hash)
        expect(result[:policy]).not_to be_nil
      end
    end
  end
end
