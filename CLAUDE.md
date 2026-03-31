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

## VPN Validation

`ClusterConfig` includes optional VPN configuration via `Types::VpnConfig`. The
VPN config is validated before `ClusterConfig` coercion -- if a VPN hash is present
but malformed, a clear error is raised rather than a cryptic Dry::Struct failure.
VPN-enabled clusters synthesize an additional NLB listener for WireGuard UDP traffic.


## Dynamic node_index via IMDSv2

Worker nodes use EC2 Instance Metadata Service v2 (IMDSv2) to dynamically
determine their `node_index` at boot time rather than relying on static
Terraform indices. This solves the ASG replacement problem where Terraform's
`count.index` becomes stale after instance recycling.

The cloud-init template queries IMDSv2 for the instance ID, then uses a
tag-based lookup to resolve the node's position in the cluster:

```ruby
# In BareMetal::CloudInit.generate()
# IMDSv2 token acquisition + instance identity
imdsv2_token = "$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
instance_id = "$(curl -s -H 'X-aws-ec2-metadata-token: #{imdsv2_token}' http://169.254.169.254/latest/meta-data/instance-id)"
```

This replaces the previous pattern where `node_index` was baked into the launch
template at Terraform plan time. With IMDSv2, the index is resolved at boot,
making ASG scaling and replacement deterministic.

## terraform_base64encode() Fix

The `NixosBase` backend previously used `base64encode()` for cloud-init
user_data, which is a Terraform built-in that operates on string literals. For
dynamic content (interpolated variables, template references), this caused
plan-time errors because the string wasn't fully resolved yet.

The fix uses `terraform_base64encode()` from `pangea-core`'s expression helpers,
which wraps the content in Terraform's native `base64encode()` function call
rather than evaluating it at synthesis time:

```ruby
# Before (broken for dynamic content):
user_data = Base64.strict_encode64(cloud_init_content)

# After (works with Terraform interpolation):
user_data = Pangea::Core::Expressions.terraform_base64encode(cloud_init_content)
```

This generates `base64encode(...)` in the Terraform JSON output, letting
Terraform handle the encoding at apply time when all variables are resolved.

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

## Typed Result Classes

Backend phase methods return typed result structs from `Pangea::Contracts` (pangea-core):

| Contract | Phase | Key fields |
|----------|-------|------------|
| `NetworkResult` | `create_network` | vpc, subnets, security_groups, nat |
| `IamResult` | `create_iam` | roles, policies, instance_profiles |
| `ClusterResult` | `create_cluster` | control_plane, endpoint, certificate_authority |
| `ArchitectureResult` | Full return | network, iam, cluster, node_pools |

These contracts enforce that all backends return the same typed shape regardless
of cloud provider. Templates and architectures can rely on `result.network.vpc`
rather than provider-specific hash keys.

## TypedSynthesizerContext

`spec/support/typed_synthesizer_context.rb` provides a test helper that wraps
`TerraformSynthesizer` with real `Dry::Struct` type validation. Tests using
`TypedSynthesizerContext` verify that resource function calls pass type checks
at synthesis time, catching type mismatches before deployment.

```ruby
# spec/typed_synthesizer_context_spec.rb
RSpec.describe 'TypedSynthesizerContext' do
  let(:ctx) { TypedSynthesizerContext.new }

  it 'validates types on resource calls' do
    expect { ctx.aws_vpc(:test, cidr_block: 123) }.to raise_error(Dry::Struct::Error)
  end
end
```

## Typed Backend Contract (shared examples)

`spec/support/shared_examples/typed_backend_contract.rb` defines shared RSpec
examples that all backends must pass. Ensures each backend returns the correct
contract types from each phase method:

```ruby
RSpec.shared_examples 'typed backend contract' do
  it 'returns NetworkResult from create_network' do
    result = backend.create_network(synth, name, config, tags)
    expect(result).to be_a(Pangea::Contracts::NetworkResult)
  end
end
```

## 3-Tier Subnet Architecture

Network phase creates a 3-tier x 3-AZ subnet layout with explicit routing:

| Tier | AZs | Routing | Purpose |
|------|-----|---------|---------|
| public | a, b, c | IGW (direct internet) | ALB, NAT gateway, bastion |
| web | a, b, c | NAT gateway (egress only, via public-a) | App servers, K3s nodes |
| data | a, b, c | VPC-local only (no internet) | RDS, ElastiCache, etcd |

- NAT gateway lives in `public-a`; web-tier route tables point to it
- Data tier has no NAT/IGW routes — fully isolated
- Each tier gets its own route table; no shared routes between tiers

## Configurable Load Balancers

Load balancers are created in the backend, not hand-crafted in templates.
Three LB types, each independently toggleable:

| LB | Type | Default | Config key | Purpose |
|----|------|---------|------------|---------|
| ALB | Application | off | `alb_enabled` | HTTP/HTTPS ingress (web traffic) |
| VPN NLB | Network | off | `vpn.enabled` | WireGuard UDP (VPN tunnel) |
| K8s API NLB | Network | always on | — | Internal stable endpoint for kubelet/workers |

- ALB supports HTTP (80) and HTTPS (443) listeners
- VPN NLB uses UDP on the configured WireGuard port
- K8s API NLB is internal-only, TCP 6443, created by every NixOS backend

## Etcd Backup Toggle

`ClusterConfig.etcd_backup_enabled` (default: `true` in production profile,
`false` in dev profile) controls whether S3 etcd backup resources are created.
When disabled, no S3 bucket, IAM policy, or CronJob is synthesized — reducing
cost and complexity for ephemeral dev clusters.
