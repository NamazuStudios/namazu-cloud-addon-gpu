# The tenant contract — the variables that are NOT the addon's. Never redeclare
# these in addon-owned files; they are fed by the namazu-cloud-addon-runner
# from its inputs (organization_id, the tenant identity, billable/state via
# --contract, the EKS wiring) and by the manifest.yaml bindings when an addon
# deliberately rebinds one.

variable "instance_id" {
  description = "Instance-plan tenant id. Null on sandboxes (per_user)."
  type        = string
  default     = null
}

variable "workspace_id" {
  description = "Per-user sandbox workspace id. Null on instance plans."
  type        = string
  default     = null
}

variable "organization_id" {
  description = "The org's database unique id (audit-tag key: organization_id; billing rollups)."
  type        = string
}

variable "billable" {
  description = "Cost-rollup flag (audit tag: billable)."
  type        = bool
  default     = true
}

variable "state" {
  description = "Sandbox lifecycle state (audit tag: state). Null on instance plans."
  type        = string
  default     = null
}

variable "product_sku" {
  description = "Notational product sku (node label / EC2 tag; audit filtering)."
  type        = string
  default     = null
}

variable "eks_cluster_name" {
  description = "EKS cluster the tenant runs in (provider wiring via the exec plugin)."
  type        = string
}

variable "eks_cluster_role_arn" {
  description = "IAM role ARN the EKS exec plugin assumes to talk to the cluster."
  type        = string
}

variable "app_dns_name" {
  description = "The tenant's app DNS name (audit label; null on sandboxes)."
  type        = string
  default     = null
}

variable "architecture" {
  description = "Tenant CPU architecture (scheduling hints, if an addon runs anything)."
  type        = string
  default     = "amd64"
}

variable "tags" {
  description = "Caller-provided extra tags, merged on top of the audit tags."
  type        = map(string)
  default     = {}
}
