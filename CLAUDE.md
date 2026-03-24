# pangea-kubernetes

Cloud-agnostic Kubernetes abstractions for the Pangea infrastructure DSL.
Provides `kubernetes_cluster()` and `kubernetes_node_pool()` functions that
compile to provider-specific Terraform JSON via backend modules. All code
is **hand-written** (not auto-generated).

## Structure

```
lib/
  pangea-kubernetes.rb                          # Entry point (requires all modules)
  pangea-kubernetes/version.rb                  # Version constant
  pangea/
    kubernetes/
      architecture.rb                           # kubernetes_cluster() / kubernetes_node_pool() API
      backend_registry.rb                       # Lazy-loading backend resolver
      load_balancer.rb                          # Elastic LB tier composition
      types.rb                                  # Core types (ClusterConfig, NodePoolConfig, etc.)
      types/
        control_plane_config.rb                 # Control plane tuning
        etcd_config.rb                          # etcd configuration
        firewall_config.rb                      # Firewall rules
        k3s_config.rb                           # K3s distribution options
        kernel_config.rb                        # Kernel parameters
        kubernetes_config.rb                    # Vanilla K8s distribution options
        pki_config.rb                           # PKI / certificate configuration
        secrets_config.rb                       # Secrets (sops-nix paths)
        wait_for_dns_config.rb                  # DNS readiness checks
      backends/
        base.rb                                 # Backend contract interface (Base module)
        nixos_base.rb                           # Shared NixOS backend logic
        aws_eks.rb                              # AWS EKS (managed)
        aws_nixos.rb                            # AWS EC2 + NixOS k3s
        gcp_gke.rb                              # GCP GKE (managed)
        gcp_nixos.rb                            # GCP GCE + NixOS k3s
        azure_aks.rb                            # Azure AKS (managed)
        azure_nixos.rb                          # Azure VM + NixOS k3s
        hcloud_k3s.rb                           # Hetzner Cloud + NixOS k3s
      bare_metal/
        cloud_init.rb                           # Cloud-init user_data generator for NixOS k3s
        cluster_reference.rb                    # External cluster reference type
spec/
  spec_helper.rb
  support/                                      # Shared test helpers
  architecture/                                 # Architecture integration tests
  backend_registry/                             # Registry resolution tests
  backends/                                     # Per-backend unit tests
    aws_eks/  aws_nixos/  gcp_gke/  gcp_nixos/
    azure_aks/  azure_nixos/  hcloud_k3s/  nixos_base/
    base_spec.rb  load_provider_spec.rb
  bare_metal/                                   # Cloud-init and cluster ref tests
  cross_backend/                                # Cross-backend compatibility tests
  load_balancer/                                # Elastic LB tier tests
  types/                                        # Dry::Struct type validation tests
```

## Architecture

```
kubernetes_cluster(:name, config)
  |
  v
BackendRegistry.resolve(config.backend)
  |
  +-- Managed backends (delegate to cloud-native K8s)
  |     aws     -> AwsEks    (EKS)
  |     gcp     -> GcpGke    (GKE)
  |     azure   -> AzureAks  (AKS)
  |
  +-- NixOS backends (k3s/k8s on NixOS VMs via blackmatter-kubernetes)
        aws_nixos   -> AwsNixos   (LT+ASG+NLB, NixOS)
        gcp_nixos   -> GcpNixos   (GCE + NixOS)
        azure_nixos -> AzureNixos (Azure VM + NixOS)
        hcloud      -> HcloudK3s  (Hetzner + NixOS)
```

### Phase pipeline

Each `kubernetes_cluster()` call executes four phases:
1. **Network** -- VPC/VNet/network creation (if `config.network` is set)
2. **IAM** -- Roles, service accounts, managed identities
3. **Cluster** -- The K8s control plane (EKS/GKE/AKS or NixOS server)
4. **Node Pools** -- Worker nodes (ASGs, instance groups, or Hetzner servers)

Returns an `ArchitectureResult` with `.cluster`, `.network`, `.iam`, `.node_pools`.

## Backend contract

Every backend implements `Pangea::Kubernetes::Backends::Base`:

| Method | Purpose |
|--------|---------|
| `backend_name` | Symbol identifier (`:aws`, `:hcloud`, etc.) |
| `managed_kubernetes?` | `true` for EKS/GKE/AKS, `false` for NixOS |
| `required_gem` | Provider gem name (`pangea-aws`, `pangea-hcloud`, etc.) |
| `load_provider!` | Require the provider gem |
| `create_network(synth, name, config, tags)` | Phase 1 |
| `create_iam(synth, name, config, tags)` | Phase 2 |
| `create_cluster(synth, name, config, result, tags)` | Phase 3 |
| `create_node_pool(synth, name, cluster_ref, pool_config, tags)` | Phase 4 |

NixOS backends share logic via `NixosBase` -- cloud-init generation, FluxCD
bootstrap, sops-nix secrets, blackmatter-kubernetes profile selection.

### AwsNixos compute pattern (ASG-based)

All AWS NixOS compute uses ASGs — no raw `aws_instance` resources. The
`create_cluster` method produces:

```
aws_launch_template   (AMI, instance type, cloud-init, IMDSv2, encrypted gp3, IAM profile, SG)
aws_autoscaling_group (min/max/desired from system_node_pool, LT ref, subnets)
aws_lb                (internal NLB — stable endpoint for workers)
aws_lb_target_group   (TCP 6443, health check)
aws_lb_listener       (TCP 6443 → target group)
aws_autoscaling_attachment (ASG → target group)
```

Returns a `ControlPlaneRef` struct that:
- `ipv4_address` → delegates to `nlb.dns_name` (used by `build_agent_cloud_init`)
- Carries `subnet_ids`, `sg_id`, `instance_profile_name`, `ami_id`, `key_name`
  so `create_worker_pool` reads infra context from the CP ref, not tags

Workers use the same LT+ASG pattern. `create_worker_pool` reads IAM/SG/subnet
from the `ControlPlaneRef` to ensure parity with the control plane.

### GitOps operator selection

`ClusterConfig.gitops_operator` selects the GitOps bootstrap mechanism:
- `:fluxcd` (default) — FluxCDConfig passed to cloud-init, manifests auto-deployed
- `:argocd` — ArgocdConfig passed to cloud-init, ArgoCD bootstrapped at boot
- `:none` — no GitOps operator, manual cluster management

Cloud-init writes the operator config to `/etc/pangea/cluster-config.json`.
The NixOS module (blackmatter-kubernetes) reads the JSON and writes operator
manifests to the k3s auto-deploy directory. Credentials are created by a
separate systemd service after the API is ready.

### Karpenter IAM (opt-in)

`ClusterConfig.karpenter_enabled = true` creates a Karpenter IRSA IAM role
and instance profile at Terraform time. Karpenter itself is deployed
post-cluster via the GitOps repo (HelmRelease).

### Parked mode

System pool `min_size: 0` sets the CP ASG to 0 instances. All infrastructure
(VPC, IAM, NLB, LTs, key pairs) remains — only instances are terminated.
Credentials stay static across park/unpark cycles.

### Bootstrap chain

```
Layer 0 (Terraform):  VPC, IAM, ASG, NLB, Karpenter IAM (opt-in)
Layer 1 (Cloud-init): NixOS reads config JSON → k3s + GitOps operator
Layer 2 (GitOps):     Karpenter, workloads, everything else
```

The akeyless-k8s GitOps repo (`pleme-io/akeyless-k8s`) follows the standard
FluxCD structure: `clusters/{name}/{flux-system,infrastructure,apps}`.

## Key types

| Type | Purpose |
|------|---------|
| `ClusterConfig` | Top-level cluster configuration (backend, version, region, node pools, FluxCD, NixOS) |
| `NodePoolConfig` | Node pool sizing, instance types, labels, taints |
| `NetworkConfig` | VPC CIDR, pod/service CIDR, subnet IDs, endpoint visibility |
| `FluxCDConfig` | GitOps bootstrap (source URL, auth, SOPS, reconciliation) |
| `NixOSConfig` | NixOS image, flake URL, k3s/kubernetes options, secrets |
| `LoadBalancerConfig` | Elastic LB tier (HAProxy fleet, BGP/VRRP for bare metal) |
| `DeploymentContext` | Environment metadata (production/staging/development) |

## NixOS / bare metal specifics

- **Cloud-init**: `BareMetal::CloudInit.generate()` produces cloud-init user_data
  that writes `/etc/pangea/cluster-config.json` on NixOS servers
- **Profiles**: Maps to blackmatter-kubernetes profiles (`cilium-standard`,
  `flannel-production`, `calico-hardened`, `istio-mesh`, etc.)
- **Distributions**: `:k3s` (default) or `:kubernetes` (vanilla)
- **Secrets**: sops-nix decrypted paths for age keys, SSH keys, tokens
- **FluxCD**: Full GitOps bootstrap with SSH or token auth, SOPS decryption

## Load balancer tier

Two-tier architecture for production:
- **Tier 1 (External)**: Fleet of NixOS HAProxy VMs behind cloud LB
- **Tier 2 (In-Cluster)**: Cilium eBPF (L4) + Istio Gateway (L7)

Bare metal mode adds BGP/VRRP (HAProxy + BIRD) with virtual IPs.

## Dependencies

- pangea-core ~> 0.2
- terraform-synthesizer ~> 0.0.28
- dry-types ~> 1.7
- dry-struct ~> 1.6
- Provider gems loaded lazily per backend:
  - `pangea-aws` (aws, aws_nixos)
  - `pangea-gcp` (gcp, gcp_nixos)
  - `pangea-azure` (azure, azure_nixos)
  - `pangea-hcloud` (hcloud)

## Testing

```sh
bundle exec rspec                              # Run all tests
bundle exec rspec spec/backends/               # Backend tests only
bundle exec rspec spec/types/                  # Type validation tests
bundle exec rspec spec/architecture/           # Integration tests
bundle exec rspec spec/bare_metal/             # Cloud-init tests
bundle exec rspec spec/cross_backend/          # Cross-backend compat
bundle exec rspec spec/load_balancer/          # LB tier tests
```

## Adding a new backend

1. Create `lib/pangea/kubernetes/backends/new_backend.rb`
2. Include `Pangea::Kubernetes::Backends::Base` (or extend `NixosBase`)
3. Implement all contract methods (`create_cluster`, `create_node_pool`, etc.)
4. Register in `BackendRegistry::BACKEND_MAP`
5. Add specs under `spec/backends/new_backend/`
6. Add cross-backend specs if the new backend has unique constraints
