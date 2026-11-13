# GPU authorization — what the capability taint is for.
#
# feature.tf's pools taint GPU nodes with `nvidia.com/gpu=present:NoSchedule`
# (plus `dedicated=tenant` and the per-tenant identity taint). The taint is
# the SCHEDULING gate: a pod that doesn't tolerate it cannot land on a GPU
# node at all. But the taint's key/value is fixed and well-known — any pod
# may carry the toleration — so the authorization decision lives HERE, at
# admission, in this addon's own policy.
#
# This is a PER-TENANT policy: this root is applied once per GPU tenant (D4 —
# per-tenant opt-in GPU is permanent), so this policy's very existence is the
# tenant's GPU enablement. The binding selects exactly this tenant's
# namespace by its identity label, so it cannot be dodged by another tenant
# and cannot be self-stamped (namespace labels need cluster-scoped RBAC).
#
# Cross-tenant protection is NOT this policy's job: tenant A tolerating
# tenant B's identity taint is stopped by the cluster's require-tenant-pin
# policy — but only once A is at tenant_billing_action=deny. This policy
# governs whether a GPU-enabled tenant uses GPUs within its granted shape.
#
# Cost ceiling stays in the POOL config (feature.tf): per-generation
# instance_types allow-lists and `nvidia.com/gpu` limits are the aggregate
# cap. The one thing a pool limit cannot express — a PER-POD cap, so one pod
# cannot consume the tenant's whole GPU budget — is validation 3 below
# (max_gpus_per_pod; 0 disables it).

resource "kubectl_manifest" "gpu_authorization_policy" {

  apply_only = true

  yaml_body = <<-YAML
    apiVersion: admissionregistration.k8s.io/v1
    kind: ValidatingAdmissionPolicy
    metadata:
      name: gpu-authorization
    spec:
      failurePolicy: Fail
      matchConstraints:
        resourceRules:
          - apiGroups: [""]
            apiVersions: ["v1"]
            operations: ["CREATE"]
            resources: ["pods"]
      variables:
        # Any container or initContainer asks for the GPU extended resource.
        - name: requestsGpu
          expression: |
            (has(object.spec.containers) && object.spec.containers.exists(
              c,
              has(c.resources)
              && ((has(c.resources.limits) && 'nvidia.com/gpu' in c.resources.limits)
                  || (has(c.resources.requests) && 'nvidia.com/gpu' in c.resources.requests))
            ))
            || (has(object.spec.initContainers) && object.spec.initContainers.exists(
              c,
              has(c.resources)
              && ((has(c.resources.limits) && 'nvidia.com/gpu' in c.resources.limits)
                  || (has(c.resources.requests) && 'nvidia.com/gpu' in c.resources.requests))
            ))
        # The scheduling gate's toleration — same key the pools taint with.
        - name: toleratesGpuTaint
          expression: |
            has(object.spec.tolerations) && object.spec.tolerations.exists(
              t,
              t.key == 'nvidia.com/gpu'
              && (t.operator == 'Exists' || (t.operator == 'Equal' && t.value == 'present'))
              && (!has(t.effect) || t.effect == 'NoSchedule')
            )
        # Per-pod ceiling from the addon's tenant config (0 = uncapped).
        - name: gpuPerPodCap
          expression: "${var.gpu.max_gpus_per_pod}"
      auditAnnotations:
        - key: gpu-authorization
          valueExpression: "variables.requestsGpu ? 'gpu-request' : 'no-gpu'"
      validations:
        # 1. A pod that tolerates the GPU taint must actually request GPUs —
        #    otherwise CPU workloads can park on (and pay for) GPU nodes.
        - expression: "!variables.toleratesGpuTaint || variables.requestsGpu"
          reason: Forbidden
          message: "pod tolerates the GPU capability taint (nvidia.com/gpu=present) but requests no nvidia.com/gpu — CPU workloads may not land on GPU nodes."
        # 2. A GPU request must carry the toleration, so an admitted GPU pod
        #    is actually schedulable on a GPU node (else it Pending forever).
        - expression: "!variables.requestsGpu || variables.toleratesGpuTaint"
          reason: Forbidden
          message: "pod requests nvidia.com/gpu but does not tolerate the GPU capability taint nvidia.com/gpu=present:NoSchedule — it would never schedule."
        # 3. Per-pod GPU cap (pool limits are aggregate; this bounds one pod).
        - expression: |
            variables.gpuPerPodCap <= 0 || (
              (!has(object.spec.containers) || object.spec.containers.all(
                c,
                !has(c.resources) || !has(c.resources.limits)
                || !('nvidia.com/gpu' in c.resources.limits)
                || int(c.resources.limits['nvidia.com/gpu']) <= variables.gpuPerPodCap
              ))
              && (!has(object.spec.initContainers) || object.spec.initContainers.all(
                c,
                !has(c.resources) || !has(c.resources.limits)
                || !('nvidia.com/gpu' in c.resources.limits)
                || int(c.resources.limits['nvidia.com/gpu']) <= variables.gpuPerPodCap
              ))
            )
          reason: Forbidden
          message: "pod requests more than the per-pod GPU cap for this tenant — one pod may not consume the tenant's whole GPU budget; split the workload or raise gpu.max_gpus_per_pod."
  YAML

}

resource "kubectl_manifest" "gpu_authorization_binding" {

  apply_only = true

  yaml_body = yamlencode({
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata = {
      name = "gpu-authorization-${local.addon_namespace}"
    }
    spec = {
      policyName        = "gpu-authorization"
      validationActions = ["Deny", "Audit"]
      matchResources = {
        namespaceSelector = {
          matchExpressions = [
            {
              key      = local.tenant_label_key
              operator = "In"
              values   = [local.addon_namespace]
            },
          ]
        }
      }
    }
  })

  depends_on = [kubectl_manifest.gpu_authorization_policy]

}
