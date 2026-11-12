# Addon-owned inputs — fed from this repo's manifest.yaml `input` bindings.
# Contract variables (instance_id, organization_id, ...) are NOT declared here
# and never will be: see 20-variables.tf and author rule 1 in feature.tf.
#
# The per-tenant knobs live in ONE object so the manifest can bind the
# tenant baseline's whole `addon_gpu` output in a single `$instance.` ref
# (`gpu: $instance.addon_gpu`) — one binding, every knob, resolved per
# invocation. Defaults mirror the baseline's pre-addon posture exactly
# (general_purpose_gpu_* in namazu-cloud-instance): g5/g6 pools exist with
# limit 0 (provision-inert), g4dn/g7 absent, every -xl ceiling 0 forever.

variable "gpu" {
  description = "Per-tenant GPU tier configuration. enable flags render/destroy whole generations (a disabled generation's NodePools are absent, which destroys them on apply — Karpenter drains and terminates their nodes). limits are per-NodePool `nvidia.com/gpu` ceilings (0 = pool exists but can never provision). xl_enabled renders the self-reclaiming 4+ GPU pools at all. max_gpus_per_node bounds the base pool's instance-gpu-count requirement (2 = the baseline's In [1,2]; 1 = single-GPU instances only, which also starves the -xl pool's Gt requirement)."
  type = object({
    g4dn_enabled = bool
    g5_enabled   = bool
    g6_enabled   = bool
    g7_enabled   = bool
    xl_enabled   = bool

    g4dn_limit    = number
    g5_limit      = number
    g6_limit      = number
    g7_limit      = number
    g4dn_xl_limit = number
    g5_xl_limit   = number
    g6_xl_limit   = number
    g7_xl_limit   = number

    g4dn_instance_types = list(string)
    g5_instance_types   = list(string)
    g6_instance_types   = list(string)
    g7_instance_types   = list(string)

    max_gpus_per_node = number
    xl_expire_after   = string
    root_volume_size  = string

    # Per-POD gpu cap for the GPU authorization policy (50-gpu_authorization.tf):
    # a NodePool's `nvidia.com/gpu` limit caps the pool in AGGREGATE, so one
    # pod can still consume a tenant's entire GPU budget. 0 (default) disables
    # the per-pod check and leaves the ceiling entirely to the pool limits.
    max_gpus_per_pod = optional(number, 0)

    # Set by the tenant baseline from its billing_suspended input (the
    # zero-compute billing hold, namazu-cloud-instance PR #89) — not a
    # tenant tfvars knob. While true every pool's limits drop to zero so
    # Karpenter provisions nothing new, the exact shape the baseline
    # applied to its own pools.
    suspended = optional(bool, false)
  })

  default = {
    g4dn_enabled = false
    g5_enabled   = true
    g6_enabled   = true
    g7_enabled   = false
    xl_enabled   = true

    g4dn_limit    = 0
    g5_limit      = 0
    g6_limit      = 0
    g7_limit      = 0
    g4dn_xl_limit = 0
    g5_xl_limit   = 0
    g6_xl_limit   = 0
    g7_xl_limit   = 0

    # The baseline's per-generation allow-lists (aws/*/variables.tf,
    # general_purpose_gpu_g<gen>_instance_types) — every size in the family,
    # including the 4+ GPU sizes the -xl pools select via instance-gpu-count.
    g4dn_instance_types = ["g4dn.xlarge", "g4dn.2xlarge", "g4dn.4xlarge", "g4dn.8xlarge", "g4dn.12xlarge", "g4dn.16xlarge", "g4dn.metal"]
    g5_instance_types   = ["g5.xlarge", "g5.2xlarge", "g5.4xlarge", "g5.8xlarge", "g5.12xlarge", "g5.16xlarge", "g5.24xlarge", "g5.48xlarge"]
    g6_instance_types   = ["g6.xlarge", "g6.2xlarge", "g6.4xlarge", "g6.8xlarge", "g6.12xlarge", "g6.16xlarge", "g6.24xlarge", "g6.48xlarge"]
    g7_instance_types   = ["g7.2xlarge", "g7.4xlarge", "g7.8xlarge", "g7.12xlarge", "g7.24xlarge", "g7.48xlarge"]

    max_gpus_per_node = 2
    xl_expire_after   = "2h"
    root_volume_size  = "100Gi"
    max_gpus_per_pod  = 0
  }
}

variable "karpenter_node_role_name" {
  description = "Name of the cluster's Karpenter node IAM role (the baseline's karpenter_node_role_name input; the GPU EC2NodeClass launches nodes under it). Bound from the tenant baseline: $instance.karpenter_node_role_name."
  type        = string
}

variable "capacity_types" {
  description = "Capacity types the GPU NodePools may launch — a PER-TENANT choice the consuming fork makes in its matrix entry (contract), not a baseline output: the baseline carries zero gpu knowledge. Defaults to on-demand only (the safe posture); multi-AZ tenants may add spot (the old HA rule: spot only when the tenant spans >1 AZ, so one AZ's spot capacity loss is survivable)."
  type        = list(string)
  default     = ["on-demand"]
}
