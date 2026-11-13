# GPU node capacity — the opt-in general-purpose GPU Karpenter tiers,
# ported 1:1 from namazu-cloud-instance's aws/{high_availability,
# single_instance,per_user} karpenter.tf (the paired PR there removes them
# from the baseline: GPU capacity is per-tenant opt-in now, installed by
# each org fork). Behavior notes that came with the port, because they were
# paid for in incidents, not invented:
#
#   - each generation renders as TWO pools with a HARD service-label split:
#     `general-purpose-gpu-<gen>` (1..max_gpus_per_node GPU sizes,
#     expireAfter 168h — single-GPU workloads may run indefinitely) and
#     `general-purpose-gpu-<gen>-xl` (Gt that count, expireAfter
#     gpu.xl_expire_after, default 2h — big machines self-reclaim: a
#     forgotten 4x-GPU on-demand node costs ~$5-10/h, so Karpenter drains
#     and replaces it on expiry, fresh timer and all).
#   - the service label differs between base and -xl, so a pod selecting the
#     base tier can never be ratcheted onto a 4x-GPU machine by batch
#     packing (2026-10-24: a 1-GPU pod provisioned a g5.24xlarge).
#   - GPU disruption is WhenEmpty/10m, NOT WhenEmptyOrUnderutilized/30s
#     (issue #63): a bound-but-still-pulling pod reads as underutilized, so
#     consolidation destroyed nodes mid image-pull (~27GB CUDA/model
#     images), and 30s reaping forced every dispatch into a full cold pull.
#   - the tenant taint pins nodes to one tenant; only pods carrying the
#     matching cloud.namazustudios.com/<instance_id|workspace_id>
#     toleration (added by the baseline's elements + mongo modules) can
#     schedule here.
#
# The two author rules (contract, stated inline so consumers inherit them):
#  1. NEVER re-declare a variable from 20-variables.tf — those are the
#     tenant contract, not yours. Addon-semantics inputs live in
#     variables.tf and are fed from manifest.yaml's `input` bindings.
#  2. NEVER couple to another addon except through its outputs (via
#     `$addon.<id>.<output>` bindings in manifest.yaml).

locals {

  # Scheduling label keys — the platform contract (aws/high_availability/
  # locals.tf). Declared here, not in 10-locals.tf, because the contract
  # file owns the audit-tag set; these are the keys the baseline's pods pin
  # nodeAffinity on, so they must match the baseline exactly.
  label = {
    service      = "cloud.namazustudios.com/service"
    instance_id  = "cloud.namazustudios.com/instance_id"
    workspace_id = "cloud.namazustudios.com/workspace_id"
    product_sku  = "cloud.namazustudios.com/product_sku"
  }

  # Instance tenants taint/pin on instance_id; sandbox (per_user) tenants
  # on workspace_id. Either way the value is the tenant identity, which is
  # also this addon's namespace (10-locals.tf).
  tenant_label_key = local.is_instance ? local.label.instance_id : local.label.workspace_id

  # Same shape as the baseline's karpenter_node_labels: the audit set from
  # 10-locals.tf plus the notational product_sku (Karpenter-only). Null-safe
  # here because product_sku is nullable in the addon contract (the
  # baseline root requires it).
  node_labels = merge(
    local.common_labels,
    var.product_sku != null ? { (local.label.product_sku) = var.product_sku } : {},
  )

  # karpenter.sh/discovery = <region>-<cluster>: the cluster-level Karpenter
  # discovery tag (the subnets + security groups tenant nodes land in).
  karpenter_discovery_tag_value = "${data.aws_region.current.region}-${var.eks_cluster_name}"

  # The WhenEmpty consolidation delay: how long an EMPTY gpu node lingers
  # before Karpenter terminates it. The contract's optional
  # `gpu.consolidate_after` (a Go duration; default 10m) — the tenant's
  # cost-vs-warmth dial: shorter = the node's bill stops sooner after the
  # queue drains (the image cache dies with it); longer = the next
  # dispatch skips the pull. (The tenant asked 2026-11-13: "is there a
  # simple variable that governs the WhenEmpty consolidation?" — there
  # wasn't.)
  disruption_gpu = {
    consolidationPolicy = "WhenEmpty"
    consolidateAfter    = try(var.gpu.consolidate_after, "10m")
  }

  # Base pool admits 1..max_gpus_per_node GPUs per instance ("1","2" today;
  # "1" only for single-GPU tenants), -xl takes the Gt side of the split.
  gpu_count_values = [for n in range(1, var.gpu.max_gpus_per_node + 1) : tostring(n)]

  # billing_suspended (the baseline's zero-compute billing hold, folded
  # into this map by the tenant baseline): every pool's limits drop to
  # zero so Karpenter provisions nothing new — the exact shape the
  # baseline applied to its own pools (namazu-cloud-instance PR #89).
  # limits only gate PROVISIONING; nodes already launched are terminated
  # by the baseline's own post-apply path, not by this addon.
  suspended_limits = {
    cpu              = "0"
    memory           = "0Gi"
    "nvidia.com/gpu" = "0"
  }

  generations = {
    g4dn = {
      enabled        = var.gpu.g4dn_enabled
      instance_types = var.gpu.g4dn_instance_types
      limit          = var.gpu.g4dn_limit
      xl_limit       = var.gpu.g4dn_xl_limit
    }
    g5 = {
      enabled        = var.gpu.g5_enabled
      instance_types = var.gpu.g5_instance_types
      limit          = var.gpu.g5_limit
      xl_limit       = var.gpu.g5_xl_limit
    }
    g6 = {
      enabled        = var.gpu.g6_enabled
      instance_types = var.gpu.g6_instance_types
      limit          = var.gpu.g6_limit
      xl_limit       = var.gpu.g6_xl_limit
    }
    g7 = {
      enabled        = var.gpu.g7_enabled
      instance_types = var.gpu.g7_instance_types
      limit          = var.gpu.g7_limit
      xl_limit       = var.gpu.g7_xl_limit
    }
  }

  karpenter_gpu_pools = merge(
    {
      for gen, cfg in local.generations : "general-purpose-gpu-${gen}" => {
        instance_types = cfg.instance_types
        limits = var.gpu.suspended ? local.suspended_limits : {
          cpu              = "1k"
          memory           = "500Gi"
          "nvidia.com/gpu" = tostring(cfg.limit)
        }
        expire_after = "168h"
        requirements = [{ key = "karpenter.k8s.aws/instance-gpu-count", operator = "In", values = local.gpu_count_values }]
      }
      if cfg.enabled
    },
    {
      for gen, cfg in local.generations : "general-purpose-gpu-${gen}-xl" => {
        instance_types = cfg.instance_types
        limits = var.gpu.suspended ? local.suspended_limits : {
          cpu              = "1k"
          memory           = "500Gi"
          "nvidia.com/gpu" = tostring(cfg.xl_limit)
        }
        expire_after = var.gpu.xl_expire_after
        requirements = [{ key = "karpenter.k8s.aws/instance-gpu-count", operator = "Gt", values = [tostring(var.gpu.max_gpus_per_node)] }]
      }
      if cfg.enabled && var.gpu.xl_enabled
    },
  )
}

data "aws_iam_role" "karpenter_node_role" {
  name = var.karpenter_node_role_name
}

# The dedicated GPU EC2NodeClass: identical role/AMI/SG/subnet wiring to the
# tenant's shared class, plus a larger root volume (CUDA runtime + model
# weights don't fit the default ~20GiB AL2023 root volume — see
# namazu-cloud-instance#29) and the per-tenant tags that make instance_id /
# organization_id / product_sku filterable in Cost Explorer.
#
# apply_only = true suppresses the plan-time live read: the exec plugin
# subprocess does not reliably inherit the executor's credentials during
# planning (same reason the baseline's manifests are apply_only).
resource "kubectl_manifest" "karpenter_ec2_node_class_gpu" {

  apply_only = true

  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name   = "${local.addon_namespace}-gpu"
      labels = local.node_labels
    }
    spec = {
      role = data.aws_iam_role.karpenter_node_role.name
      amiSelectorTerms = [
        { alias = "al2023@latest" }
      ]
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = var.gpu.root_volume_size
            volumeType          = "gp3"
            deleteOnTermination = true
          }
        }
      ]
      securityGroupSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = local.karpenter_discovery_tag_value } }
      ]
      subnetSelectorTerms = [
        { tags = { "karpenter.sh/discovery" = local.karpenter_discovery_tag_value } }
      ]
      tags = merge(
        { "karpenter.sh/discovery" = local.karpenter_discovery_tag_value },
        local.node_labels
      )
    }
  })

}

# One NodePool per tier (the map keys). The taint pins nodes to a single
# tenant; the service label drives the base/-xl tier split via pod
# node-affinity, and Karpenter requires every label a pod pins
# nodeAffinity on to be declared as a requirement here too.
resource "kubectl_manifest" "karpenter_gpu_node_pool" {

  for_each = local.karpenter_gpu_pools

  apply_only = true

  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name   = "${local.addon_namespace}-${each.key}"
      labels = local.node_labels
    }
    spec = {
      template = {
        metadata = {
          labels = merge(local.node_labels, {
            (local.label.service) = each.key
          })
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "${local.addon_namespace}-gpu"
          }
          expireAfter = each.value.expire_after
          requirements = concat([
            { key = "kubernetes.io/arch", operator = "In", values = ["amd64"] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = var.capacity_types },
            { key = "node.kubernetes.io/instance-type", operator = "In", values = each.value.instance_types },
            { key = local.tenant_label_key, operator = "In", values = [local.addon_namespace] },
            { key = local.label.service, operator = "In", values = [each.key] },
          ], each.value.requirements)
          # THREE taints during the shared-NodePool transition
          # (terraform#58): the legacy per-tenant taint (this tenant's own
          # GPU pools, as always), the generic dedicated taint stamped
          # by the cluster's shared capacity pools — tenant pods tolerate
          # both (namazu-cloud-instance #99/#100) — AND the GPU capability
          # taint: the fixed, well-known key the GPU authorization policy
          # (this addon's gpu-authorization PR) keys on. A pod without that
          # toleration cannot land on a GPU node at all, so the taint is the
          # scheduling gate and the policy is the authorization gate; a
          # non-GPU tenant has neither.
          # The per-tenant taint is dropped once migrations complete.
          # NOTE: NodePool taints apply at PROVISIONING — nodes launched
          # before this change keep their old taint set until they expire
          # (expireAfter) or are drained; drain them after apply if the
          # gate must be immediate.
          taints = [
            {
              key    = "nvidia.com/gpu"
              value  = "present"
              effect = "NoSchedule"
            },
            {
              key    = "cloud.namazustudios.com/dedicated"
              value  = "tenant"
              effect = "NoSchedule"
            },
            {
              key    = local.tenant_label_key
              value  = local.addon_namespace
              effect = "NoSchedule"
            }
          ]
        }
      }
      disruption = local.disruption_gpu
      limits     = each.value.limits
    }
  })

  depends_on = [
    kubectl_manifest.karpenter_ec2_node_class_gpu,
  ]

}
