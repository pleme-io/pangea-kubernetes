# frozen_string_literal: true

module Pangea
  module Kubernetes
    # Lazy-loading registry for network backends.
    # Mirrors BackendRegistry pattern for compute backends.
    module NetworkBackendRegistry
      NETWORK_MAP = {
        vpc_cni: 'pangea/kubernetes/network_backends/vpc_cni',
        cilium: 'pangea/kubernetes/network_backends/cilium',
      }.freeze

      ALIASES = {
        aws_cni: :vpc_cni,
        eni: :vpc_cni,
        ebpf: :cilium,
      }.freeze

      CLASS_MAP = {
        vpc_cni: 'Pangea::Kubernetes::NetworkBackends::VpcCni',
        cilium: 'Pangea::Kubernetes::NetworkBackends::Cilium',
      }.freeze

      # Resolve a network backend by name.
      #
      # @param name [Symbol] Backend name or alias
      # @return [Module] The network backend module
      # @raise [ArgumentError] If the backend is unknown
      def self.resolve(name)
        name = ALIASES.fetch(name, name)
        path = NETWORK_MAP.fetch(name) do
          raise ArgumentError, "Unknown network backend: #{name}. Available: #{NETWORK_MAP.keys.join(', ')}"
        end
        require path
        Object.const_get(CLASS_MAP.fetch(name))
      end

      # Check if a network backend is compatible with a compute backend.
      #
      # @param network [Symbol] Network backend name
      # @param compute [Symbol] Compute backend name
      # @return [Boolean]
      def self.compatible?(network, compute)
        backend = resolve(network)
        backend.compatible_backends.include?(compute)
      end

      # @return [Array<Symbol>] All registered network backend names
      def self.available
        NETWORK_MAP.keys
      end
    end
  end
end
