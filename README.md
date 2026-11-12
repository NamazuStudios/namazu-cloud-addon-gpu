# namazu-cloud-addon-gpu

Opt-in **GPU node capacity** as a per-tenant addon: the general-purpose GPU
Karpenter tiers (g4dn / g5 / g6 / g7, each split into a base pool for 1-2
GPU instance sizes and a self-reclaiming `-xl` pool for 4+ GPU sizes),
ported 1:1 out of
[namazu-cloud-instance](https://github.com/NamazuStudios/namazu-cloud-instance)'s
`aws/{high_availability,single_instance,per_user}/karpenter.tf`. The paired
PR there removes them from the baseline; GPU capacity is now something an
org fork *installs* for its tenants, not something every tenant gets.

One repo = one addon = one Terraform root (contract:
[`tenant-addons-plan.md`](https://github.com/NamazuStudios/namazu-cloud-instance/blob/main/tenant-addons-plan.md)).
Inert by design: no CI, no bootstrap, no AWS role — an org fork executes
this root under **its** executor role at a pinned ref.

## What it reads (manifest.yaml bindings)

| Variable | Source | Meaning |
|---|---|---|
| `karpenter_node_role_name` | `$instance.karpenter_node_role_name` | the cluster's Karpenter node IAM role (nodes launch under it) — the ONE generic fact the baseline still carries for this addon |
| `capacity_types` | fork matrix `--contract capacity_types=[...]` | spot eligibility — the FORK's per-tenant choice (default `["on-demand"]`; multi-AZ tenants may add spot) |
| `gpu` | fork matrix `--contract gpu='{...}'` | the whole per-tenant tier config (see below) |

The baseline carries **zero gpu knowledge**: `karpenter_node_role_name` is
generic cluster wiring (it exists regardless of addons), and everything
gpu-specific — the tier config AND spot eligibility — is per-tenant fork
configuration via the runner's `contract` input
(namazu-cloud-addon-runner#4). `gpu_capacity_types` is likewise being
REMOVED from the baseline (namazu-cloud-instance#130). The only baseline
dependency left is the node role; until a tenant's baseline is re-applied
with it, installing this addon fails loudly naming the missing output (the
contract's preferred failure).

## The `gpu` input (per-tenant quota, via `--contract`)

The tier config is one JSON object passed by the consuming fork's matrix
entry (the runner forwards each line as `--contract gpu='...'`):

```hcl
gpu = {
  g4dn_enabled = false          # generation on/off; off destroys its pools
  g5_enabled   = true           #   (Karpenter drains + terminates the nodes)
  g6_enabled   = true
  g7_enabled   = false
  xl_enabled   = true           # render the 4+ GPU (-xl) pools at all

  g5_limit     = 0              # per-NodePool "nvidia.com/gpu" ceilings;
  g6_limit     = 0              #   0 = pool exists but can never provision
  g5_xl_limit  = 0              # -xl ceilings: keep 0 unless deliberately
  ...                          #   paying for 4x-GPU on-demand (~$5-10/h)

  g5_instance_types = [...]     # per-generation allow-lists
  max_gpus_per_node = 2         # base pool admits 1..N GPUs per instance;
                                #   1 = single-GPU instances only
  xl_expire_after   = "2h"      # -xl self-reclaim window
  root_volume_size  = "100Gi"   # dedicated GPU node class root volume
}
```

Defaults (when a fork's matrix entry passes no `gpu` contract) are the
baseline's old posture exactly: g5/g6 pools exist with limit 0, g4dn/g7
absent, every `-xl` ceiling 0 — nothing can provision a GPU unless the
fork's contract raises a limit.

**`suspended` no longer folds in from the baseline.** It used to ride the
baseline's `addon_gpu` output (folded from `billing_suspended`, the
zero-compute billing hold, zeroing every pool's limits while set). With the
binding gone it defaults to `false` — a billing-suspended tenant's GPU
pools stay defined with their configured limits. Two follow-up paths:
either the fork's matrix entry zeroes the limits via `--contract` when the
tenant is suspended, or a later generic `billing_suspended` baseline output
gets bound here explicitly (tracked in namazu-cloud-instance#130's
discussion).

**Single-GPU-only tenant** (the shape Dank Studios asked for):

```hcl
gpu = {
  g4dn_enabled = false
  g5_enabled   = true
  g6_enabled   = true
  g7_enabled   = false
  xl_enabled   = false
  g5_limit     = 1
  g6_limit     = 1
  g5_xl_limit  = 0
  g6_xl_limit  = 0
  g5_instance_types = ["g5.xlarge", "g5.2xlarge", "g5.4xlarge", "g5.8xlarge", "g5.16xlarge"]
  g6_instance_types = ["g6.xlarge", "g6.2xlarge", "g6.4xlarge", "g6.8xlarge", "g6.16xlarge"]
  max_gpus_per_node = 1
  xl_expire_after   = "2h"
  root_volume_size  = "100Gi"
}
```

## What it creates

- `EC2NodeClass` `<tenant>-gpu` — role = the cluster's Karpenter node role,
  `al2023@latest` AMI, `100Gi` gp3 root volume (CUDA + model weights don't
  fit the default ~20GiB — namazu-cloud-instance#29), subnet/SG selectors on
  the `karpenter.sh/discovery = <region>-<cluster>` tag, per-tenant audit
  tags + `product_sku`.
- `NodePool`s `<tenant>-general-purpose-gpu-<gen>[-xl]` — tenant-pinned via
  the `cloud.namazustudios.com/instance_id` (or `workspace_id` on sandboxes)
  NoSchedule taint, tier-split via the `cloud.namazustudios.com/service`
  label, `WhenEmpty/10m` disruption (issue #63: 30s consolidation destroyed
  nodes mid image-pull of ~27GB CUDA images), base pools `expireAfter 168h`
  and `-xl` pools `gpu.xl_expire_after` (self-reclaim).

## What the consuming org fork needs

`iam.policy.json` (feature grants, merged onto the executor role by the
fork's `bootstrap/`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "EcrAuthToken", "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"], "Resource": "*" },
    { "Sid": "KarpenterNodeRoleRead", "Effect": "Allow",
      "Action": ["iam:GetRole"],
      "Resource": ["arn:aws:iam::<account>:role/<karpenter node role name>"] }
  ]
}
```

(`ecr:GetAuthorizationToken` is required by the contract `30-providers.tf`
itself — its helm ECR registry block does a plan-time token fetch.)

`bootstrap/rbac.yaml` — the `addons-executor` ClusterRole must additionally
carry (the template's default does not):

```yaml
  - apiGroups: ["karpenter.sh"]
    resources: ["nodepools", "nodepools/status"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["karpenter.k8s.aws"]
    resources: ["ec2nodeclasses", "ec2nodeclasses/status"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
```

## Migration / ordering

The baseline used to create the same objects (`<tenant>-gpu`,
`<tenant>-general-purpose-gpu-<gen>*`) and to own the per-tenant quota via
its `addon_gpu` variable/output. Two roots must never own the same
Kubernetes object, so the order is:

1. Land the `namazu-cloud-addon-runner` `contract` input
   (namazu-cloud-addon-runner#4) and THIS repo's manifest decoupling
   (this PR), then the org forks' matrix entries gain `contract:` with the
   tenant's tier config.
2. Land the `namazu-cloud-instance` PR that removes the GPU pools **and**
   the `addon_gpu` variable/output (namazu-cloud-instance#130).
3. Re-apply each GPU tenant's baseline (pools disappear; nothing is running
   on them today — every GPU limit in every env is 0).
4. Install this addon for the tenant from its org fork (`sync.yml` matrix
   entry at a pinned ref, with the tenant's `gpu` config as `contract`
   lines).

A quota change later is: edit the `contract:` lines in the fork's
`sync.yml` matrix entry → merge → the addon's own `sync.yml` run applies
it.

## License

MIT — see [LICENSE](LICENSE).

## License & provenance

**AGPL-3.0** — see [LICENSE](LICENSE).

This is an **official Namazu Cloud addon** — it can be activated for a
**fixed fee** (the activation + review process is documented in the
[namazu-cloud-addon-example template's ADDONS.md](https://github.com/NamazuStudios/namazu-cloud-addon-example/blob/main/ADDONS.md)).

The repository is made public for **transparency and visibility**: it is
deeply connected to Namazu Cloud — the NodePools, EC2NodeClass, and quota
semantics here are the platform's GPU story. It is written for Namazu
Studios and Namazu Cloud use; derivative works are expected to come back
upstream to `NamazuStudios`, no exceptions.

## AGPL waiver for delivered work

Namazu Studios, as the copyright holder, **waives all AGPL obligations for
software installed through a purchase or other business arrangement
between Namazu Studios and the client.** The AGPL terms above govern the
code as published in this repository; work delivered to you under
contract — including any official addon activated for a fee or custom
addon authored for you — is delivered under that agreement, not under the
license's reciprocity terms.

## Built for generative AI workloads

A generative AI tenant profile that lands repeatedly: per-tenant **image
generation / LLM inference** with no noisy-neighbor contention.

- **Dedicated GPU node pools per tenant** — a tenant's diffusion workers
  schedule on GPU nodes carrying that tenant's taint; another tenant's
  burst can never steal the capacity.
- **Per-tenant quota as a product surface** — `gpu={"g5_limit": 2, ...}`
  caps the tenant's aggregate GPUs; bill the cap, not the chaos.
- **Bursty 4-GPU renders without permanent cost** — the self-reclaiming
  `-xl` pools rent 4x-GPU machines for a bounded window
  (`xl_expire_after`) and hand them back; batch video/music generation
  uses them, interactive inference does not.
- **Single-GPU shapes for serving** — `max_gpus_per_node: 1` +
  `max_gpus_per_pod: 1` keeps per-request latency predictable on
  g4dn/g5.xlarge-class instances.
- **Capacity types per tenant** — spot for batch generation, on-demand
  for serving, decided per tenant in the fork's matrix.
