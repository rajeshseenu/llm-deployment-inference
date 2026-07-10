apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: llm-chat-stack
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${REGISTRY}/helm
    chart: llm-chat-stack
    targetRevision: "*"
    # Semver wildcard: any chart version pushed to this OCI path is picked
    # up automatically. To deploy an update, package + helm push a new
    # version — no need to edit this Application again.
  destination:
    server: https://kubernetes.default.svc
    namespace: ${K8S_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      # selfHeal is intentional — the chart in ACR is the source of truth.
      # Manual kubectl edits to live resources will be reverted.
    syncOptions:
      - CreateNamespace=true
