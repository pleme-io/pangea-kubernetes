# frozen_string_literal: true

lib = File.expand_path(%(lib), __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require_relative %(lib/pangea-kubernetes/version)

Gem::Specification.new do |spec|
  spec.name                  = %(pangea-kubernetes)
  spec.version               = PangeaKubernetes::VERSION
  spec.authors               = [%(Luis Zayas)]
  spec.email                 = [%(drzthslnt@gmail.com)]
  spec.description           = %(Cloud-agnostic Kubernetes abstractions for Pangea. Compiles kubernetes_cluster() and kubernetes_node_pool() to provider-specific Terraform JSON via backend modules (AWS EKS, GCP GKE, Azure AKS, Hetzner k3s-on-NixOS).)
  spec.summary               = %(Cloud-agnostic Kubernetes abstractions for Pangea)
  spec.homepage              = %(https://github.com/pleme-io/pangea-kubernetes)
  spec.license               = %(Apache-2.0)
  spec.require_paths         = [%(lib)]
  spec.required_ruby_version = %(>=3.3.0)

  spec.files = `git ls-files -z`.split("\x0").reject do |f|
    f.match(%r{^(test|spec|features)/})
  end

  spec.add_dependency "pangea-core", "~> 0.1.0"
  spec.add_dependency "terraform-synthesizer", "~> 0.0.28"
  spec.add_dependency "dry-types", "~> 1.7"
  spec.add_dependency "dry-struct", "~> 1.6"

  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "simplecov", "~> 0.22"

  spec.metadata['rubygems_mfa_required'] = 'true'
end
