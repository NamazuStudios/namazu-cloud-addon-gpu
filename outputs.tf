# What other addons (and operators) can wire against. `$addon.gpu.<out>`
# resolves from this addon's statefile per tenant.

output "node_class_name" {
  description = "The GPU EC2NodeClass this addon owns (<tenant>-gpu)."
  value       = "${local.addon_namespace}-gpu"
}

output "node_pool_names" {
  description = "The NodePool names this addon owns, keyed by tier (general-purpose-gpu-<gen>[-xl])."
  value = {
    for tier in keys(local.karpenter_gpu_pools) : tier => "${local.addon_namespace}-${tier}"
  }
}

output "gpu_limits" {
  description = "The effective per-pool nvidia.com/gpu ceilings, keyed by tier — the tenant's quota, as applied (audit-friendly: compare against the addon_gpu input)."
  value = {
    for tier, pool in local.karpenter_gpu_pools : tier => pool.limits["nvidia.com/gpu"]
  }
}
