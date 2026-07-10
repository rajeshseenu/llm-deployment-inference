# llm-deployment-inference

A reproducible, GitOps-managed deployment of a CPU-only LLM (vLLM) with a
chat website frontend, on a single-node k3s cluster. The Helm chart is
packaged and pushed to ACR as an OCI artifact; ArgoCD watches that same
registry path with a semver wildcard (`targetRevision: "*"`) — any new
chart version you push is picked up and deployed automatically.

## Project structure

```
llm-deployment-inference/
├── install.sh                              # one-time bootstrap — run this first
├── push-chart.sh                            # package + push a new chart version later
├── uninstall.sh                             # teardown (app-only or full dependency removal)
├── website/
│   ├── index.html
│   ├── app.js
│   ├── nginx.conf.tpl                       # ${K8S_NAMESPACE} substituted at image build time
│   └── Dockerfile
├── vllm/
│   └── Dockerfile.cpu                       # fetches a HF model, bakes into a CPU vLLM image
├── helm/llm-chat-stack/
│   ├── Chart.yaml
│   ├── values.yaml                          # non-secret config only
│   └── templates/
│       ├── namespace.yaml
│       ├── vllm-deployment.yaml
│       ├── website-deployment.yaml
│       └── ingress.yaml
└── argocd/
    └── application.yaml.tpl                 # ArgoCD Application, OCI source, targetRevision "*"
```

## What `install.sh` does (one-time bootstrap)

1. Preflight checks — installs git, curl, Docker, envsubst, python3, helm if missing
2. Installs k3s (skipped if already present)
3. Prompts for registry, model, image tags, namespace, resource sizing, domain
4. Builds + pushes the vLLM and website Docker images to ACR
5. Installs ArgoCD (server-side apply, avoids a known CRD size limit issue)
6. Creates the namespace and registry pull secret directly via `kubectl`
   (secrets never touch the Helm chart or git)
7. Copies the chart locally, fills in your inputs, tags it with a unique
   timestamp-based version, and pushes it to `oci://<registry>/helm`
8. Gives ArgoCD credentials for that OCI registry, then deploys the
   `Application` (targetRevision `*`) and triggers an immediate sync
9. Waits for vLLM to become ready (several minutes on CPU — expected)
10. Prints the URL to access the chat UI

## Deploying updates after the initial install

```bash
vim helm/llm-chat-stack/values.yaml   # e.g. bump vllm.image.tag
./push-chart.sh
```
`push-chart.sh` packages the chart with a new version and pushes it to ACR.
ArgoCD (polling that registry) detects the new version automatically and
rolls it out — no `kubectl` needed, no need to touch the Application again.

To force an immediate sync instead of waiting for ArgoCD's polling interval:
```bash
kubectl -n argocd patch application llm-chat-stack --type merge -p '{"operation":{"sync":{}}}'
```

## Why secrets stay out of the chart

`values.yaml` only ever contains non-sensitive values (image references,
resource sizing, namespace, domain). Registry credentials and Hugging Face
tokens are supplied interactively to `install.sh`/`push-chart.sh` and used
directly — never stored in the chart or pushed to ACR alongside it. The
image pull secret (`acr-secret` by default) is created once, directly via
`kubectl`, and referenced by name in `values.yaml`.

## Known constraints baked into this chart (from real troubleshooting)

- **`TORCHDYNAMO_DISABLE=1`** — required on the CPU vLLM image; without it,
  `torch.compile` attempts a C++ kernel build that fails due to a missing
  header in this image's PyTorch install.
- **`strategy: Recreate`** on the vLLM Deployment — `RollingUpdate` briefly
  runs two replicas, which fails to schedule on resource-constrained
  single-node clusters.
- **`startupProbe` with a 10-minute budget** — CPU inference startup
  (model load + warmup) has been observed taking 3-5 minutes.
- Memory limits are sized with real headroom above
  `checkpoint size + VLLM_CPU_KVCACHE_SPACE` to avoid post-warmup OOM kills.
- ArgoCD's `selfHeal: true` is intentional — the chart in ACR is the single
  source of truth. Manual `kubectl edit`/`patch` on live resources will be
  reverted; push a new chart version instead.

## Tearing down

```bash
curl -sSL https://raw.githubusercontent.com/<you>/<repo>/main/uninstall.sh | bash
```
Choose app-only removal (keeps k3s/Docker/git) or full removal (everything,
for testing `install.sh` from a genuinely clean machine).
