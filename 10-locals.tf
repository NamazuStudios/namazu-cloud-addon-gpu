# Addon-root locals. Same audit-tag shape as namazu-cloud-instance's
# per_tenant/aws/<type> roots, computed here because provider `default_tags`
# must be resolvable at provider init (before resources are evaluated).
#
# The instance/sandbox null-safety is the merge-with-ternary idiom: a tenant
# carries exactly one of instance_id / workspace_id; `state` exists on the
# sandbox flavor only.

locals {

  # The tenant identity doubles as the Kubernetes namespace (repo convention).
  addon_namespace = coalesce(var.instance_id, var.workspace_id)

  is_instance = var.instance_id != null

  audit_tags = merge(
    var.instance_id != null
    ? { "cloud.namazustudios.com/instance_id" = var.instance_id }
    : {},
    var.workspace_id != null
    ? { "cloud.namazustudios.com/workspace_id" = var.workspace_id }
    : {},
    {
      "cloud.namazustudios.com/organization_id" = var.organization_id
      "cloud.namazustudios.com/billable"        = tostring(var.billable)
    },
    var.state != null
    ? { "cloud.namazustudios.com/state" = var.state }
    : {},
  )

  provider_default_tags = merge(var.tags, local.audit_tags)

  common_labels = merge(local.audit_tags,
    var.app_dns_name != null
    ? { "cloud.namazustudios.com/app_dns_name" = var.app_dns_name }
    : {},
  )
}
