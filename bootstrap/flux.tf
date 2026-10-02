# ==========================================
# Bootstrap Flux Operator + FluxInstance
# ==========================================
# The bootstrap module runs a Job in the cluster that installs the
# flux-operator Helm chart, applies the FluxInstance with create-if-missing
# semantics and waits for it to become Ready. Resources adopted by Flux are
# left alone on subsequent applies, so Terraform never fights reconciliation.
module "flux_operator" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version = "0.8.0"

  depends_on = [terraform_data.cluster]

  revision = var.bootstrap_revision

  gitops_resources = {
    instance_yaml = file("${path.module}/flux-instance.yaml")
    operator_chart = {
      version = var.flux_operator_version
    }
  }
}

# ==========================================
# Bootstrap Flux ResourceSetInputProvider
# ==========================================
# Applied after the module because the ResourceSetInputProvider and ResourceSet
# CRDs ship with the flux-operator chart, which the bootstrap Job installs.
resource "kubectl_manifest" "rsip" {
  depends_on = [module.flux_operator]

  yaml_body = <<-YAML
    apiVersion: fluxcd.controlplane.io/v1
    kind: ResourceSetInputProvider
    metadata:
      name: releases-image
      namespace: flux-system
      annotations:
        fluxcd.controlplane.io/reconcileEvery: 5m
    spec:
      type: OCIArtifactTag
      url: ${var.oci_registry}/${var.releases_artifact}
      filter:
        includeTag: "^\\d+\\.\\d+\\.\\d+$"
        # Without semver the tags sort in reverse alphabetical order, which
        # ranks 0.9.9 above 0.9.10.
        #
        # lab7: pinned instead of ">=0.0.0". The lab7/patches/ below are
        # written against this exact bundle (= HEAD of this branch, v0.11.33);
        # a newer upstream tag could change what they target, and the RSIP
        # would otherwise roll the cluster mid-measurement on its 5m poll.
        semver: "=0.11.33"
        limit: 1
      defaultValues:
        tag: "${var.releases_version}"
  YAML
}

# ==========================================
# Bootstrap Flux ResourceSet
# ==========================================
resource "kubectl_manifest" "rset" {
  depends_on = [kubectl_manifest.rsip]

  yaml_body = <<-YAML
    apiVersion: fluxcd.controlplane.io/v1
    kind: ResourceSet
    metadata:
      name: releases
      namespace: flux-system
    spec:
      inputsFrom:
      - kind: ResourceSetInputProvider
        name: releases-image
      resources:
      - apiVersion: source.toolkit.fluxcd.io/v1
        kind: OCIRepository
        metadata:
          name: releases
          namespace: flux-system
        spec:
          interval: 2m
          url: ${var.oci_registry}/${var.releases_artifact}
          ref:
            tag: "<< inputs.tag >>"
      - apiVersion: kustomize.toolkit.fluxcd.io/v1
        kind: Kustomization
        metadata:
          name: releases-crds
          namespace: flux-system
        spec:
          interval: 2m
          sourceRef:
            kind: OCIRepository
            name: releases
          path: ./crds
          prune: true
          wait: true
          # lab7: local edits on top of the upstream bundle, nothing published.
          # jsonencode(yamldecode(...)) inlines the list as one line of JSON
          # (valid YAML flow style), so there is no heredoc indentation to get
          # right, and file() content is never HCL-interpolated -- the
          # collector's $${env:...} references in the patches survive as-is.
          # yamldecode also fails the plan on a malformed patch file.
          patches: ${jsonencode(yamldecode(file("${path.module}/../lab7/patches/crds.yaml")))}
      - apiVersion: kustomize.toolkit.fluxcd.io/v1
        kind: Kustomization
        metadata:
          name: releases
          namespace: flux-system
        spec:
          interval: 2m
          dependsOn:
            - name: releases-crds
          sourceRef:
            kind: OCIRepository
            name: releases
          path: ./
          prune: true
          wait: true
          retryInterval: 30s
          # lab7: see releases-crds above.
          patches: ${jsonencode(yamldecode(file("${path.module}/../lab7/patches/releases.yaml")))}
  YAML
}
