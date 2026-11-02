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

| Variable | Binding | Meaning |
|---|---|---|
| `karpenter_node_role_name` | `$instance.karpenter_node_role_name` | the cluster's Karpenter node IAM role (nodes launch under it) |
| `gpu_capacity_types` | `$instance.gpu_capacity_types` | spot eligibility as the tenant's own baseline computes it (HA: spot only when the tenant spans >1 AZ; single_instance / per_user: spot + on-demand) |
| `gpu` | `$instance.addon_gpu` | the whole per-tenant tier config (see below) |

All three come from the **tenant baseline outputs** — the PR to
`namazu-cloud-instance` adds `karpenter_node_role_name`,
`gpu_capacity_types` and `addon_gpu` to the `per_tenant/aws/*` roots. Until
a tenant's baseline is re-applied with those outputs, installing this addon
for it fails loudly naming the missing output (the contract's preferred
failure).

## The `gpu` input (per-tenant quota)

```hcl
addon_gpu = {
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

Defaults (when a tenant's baseline doesn't override) are the baseline's old
posture exactly: g5/g6 pools exist with limit 0, g4dn/g7 absent, every `-xl`
ceiling 0 — nothing can provision a GPU unless the tenant's baseline raises
a limit. `suspended` is not a tenant knob: the baseline folds it in from
its `billing_suspended` input (the zero-compute billing hold) and it zeroes
every pool's limits while set.

**Single-GPU-only tenant** (the shape Dank Studios asked for):

```hcl
addon_gpu = {
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
`<tenant>-general-purpose-gpu-<gen>*`). Two roots must never own the same
Kubernetes object, so the order is:

1. Land the `namazu-cloud-instance` PR that removes the GPU pools **and**
   adds the outputs above.
2. Re-apply each GPU tenant's baseline (pools disappear; nothing is running
   on them today — every GPU limit in every env is 0).
3. Install this addon for the tenant from its org fork (`sync.yml` matrix
   entry, pinned ref).

A quota change later is: edit the tenant's baseline `addon_gpu` tfvars →
baseline apply → addon apply (its own `sync.yml` run).

## License

MIT — see [LICENSE](LICENSE).
