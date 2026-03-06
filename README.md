# pangea-kubernetes

Cloud-agnostic Kubernetes abstractions for the Pangea infrastructure DSL.

## Overview

Provides a unified `kubernetes_cluster` and `kubernetes_node_pool` API that compiles
to provider-specific Terraform JSON via pluggable backend modules (AWS EKS, GCP GKE,
Azure AKS, Hetzner k3s-on-NixOS). Includes bare-metal cloud-init support, elastic
load balancer abstractions, and a backend registry for extensibility. Built on pangea-core.

## Installation

```ruby
gem 'pangea-kubernetes', '~> 0.1'
```

## Usage

```ruby
require 'pangea-kubernetes'
require 'pangea-hcloud'  # backend provider

cluster = Pangea::Kubernetes::Architecture.new(
  backend: :hcloud_nixos,
  name: "my-cluster",
  version: "1.31"
)
```

Backends are lazy-loaded -- only require the provider gem for the backend you use.

## Development

```bash
nix develop
bundle exec rspec
```

## License

Apache-2.0
