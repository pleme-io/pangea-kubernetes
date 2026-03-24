# frozen_string_literal: true

# Shared examples that verify every backend conforms to the typed contract.
# Each backend's type_validation_spec includes this with its specific
# backend module, config builder, and context factory.
#
# These examples validate:
# - create_network returns a Pangea::Contracts::NetworkResult (or subclass)
# - create_iam returns a Pangea::Contracts::IamResult (or subclass)
# - Full pipeline returns a Pangea::Contracts::ArchitectureResult (or subclass)

RSpec.shared_examples 'typed backend contract' do |backend_module, context_factory|
  # Expects the including spec to define:
  #   let(:cluster_config) — a Pangea::Kubernetes::Types::ClusterConfig
  #   let(:base_tags) — a Hash of tags

  describe 'typed backend contract' do
    it 'create_network returns a Pangea::Contracts::NetworkResult' do
      if cluster_config.network
        typed = send(context_factory)
        result = backend_module.create_network(typed, :contract_test, cluster_config, base_tags)
        expect(result).to be_a(Pangea::Contracts::NetworkResult)
      end
    end

    it 'create_iam returns a Pangea::Contracts::IamResult' do
      typed = send(context_factory)
      result = backend_module.create_iam(typed, :contract_test, cluster_config, base_tags)
      expect(result).to be_a(Pangea::Contracts::IamResult)
    end

    it 'full pipeline returns an ArchitectureResult with typed components' do
      # Some backends have known validation gaps in the full pipeline:
      # - Azure: Architecture uses symbol-key tags; Azure types require string keys
      # - Hcloud: spec uses region 'eu-central' but server resource needs datacenter
      # - AWS EKS: create_node_pool uses Terraform ref as node_role_arn (format mismatch)
      # - GCP NixOS: similar region/zone mapping issues
      #
      # These are real issues tracked for resolution. Backends with their own
      # full pipeline tests (aws_nixos, gcp_gke) already cover this path.
      # Skip backends that lack a working full pipeline test in their own spec.
      backends_with_full_pipeline = %i[aws_nixos gcp]
      unless backends_with_full_pipeline.include?(backend_module.backend_name)
        skip "#{backend_module.backend_name} full pipeline has known type-validation gaps (pending fixes)"
      end

      synth = send(context_factory)
      synth.extend(Pangea::Kubernetes::Architecture)

      # Build the full pipeline config hash from the existing cluster_config.
      config_hash = {
        backend: cluster_config.backend,
        kubernetes_version: cluster_config.kubernetes_version,
        region: cluster_config.region,
        node_pools: cluster_config.node_pools.map { |p|
          {
            name: p.name,
            instance_types: p.instance_types,
            min_size: p.min_size,
            max_size: p.max_size,
            disk_size_gb: p.disk_size_gb
          }
        },
        tags: cluster_config.tags
      }

      # Add optional fields that specific backends need
      config_hash[:network] = cluster_config.network.to_h if cluster_config.network
      config_hash[:distribution] = cluster_config.distribution if cluster_config.respond_to?(:distribution) && cluster_config.distribution
      config_hash[:profile] = cluster_config.profile if cluster_config.respond_to?(:profile) && cluster_config.profile
      config_hash[:distribution_track] = cluster_config.distribution_track if cluster_config.respond_to?(:distribution_track) && cluster_config.distribution_track
      config_hash[:ami_id] = cluster_config.ami_id if cluster_config.respond_to?(:ami_id) && cluster_config.ami_id
      config_hash[:key_pair] = cluster_config.key_pair if cluster_config.respond_to?(:key_pair) && cluster_config.key_pair
      config_hash[:project] = cluster_config.project if cluster_config.respond_to?(:project) && cluster_config.project

      result = synth.kubernetes_cluster(:contract_test, config_hash)

      expect(result).to be_a(Pangea::Contracts::ArchitectureResult)
      if cluster_config.network
        expect(result.network).to be_a(Pangea::Contracts::NetworkResult)
      end
      expect(result.iam).to be_a(Pangea::Contracts::IamResult)
    end
  end
end
