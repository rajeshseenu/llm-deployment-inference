# llm-chat-gitops

A reproducible, from-scratch deployment of a CPU-only LLM (vLLM) with a chat
website frontend, on a single-node k3s cluster. Built from a working,
hand-validated configuration — every value that differs between environments
(registry, credentials, model, namespace, domain) is prompted for by
`install.sh` at runtime. Nothing is hardcoded in this repo.

## Project structure

```
llm-chat-gitops/
├── install.sh                          # the one script that does everything
├── website/
│   ├── index.html                      # chat UI
│   ├── app.js                          # calls /v1/chat/completions via same-origin proxy
│   ├── nginx.conf.tpl                  # proxies /v1/* to vllm-service internally
│   └── Dockerfile                      # bakes the above into an nginx image
├── vllm/
│   └── Dockerfile.cpu                  # fetches a HF model, bakes into a CPU vLLM image
└── k8s/
    ├── 00-namespace.yaml.tpl
    ├── 10-vllm-deployment.yaml.tpl      # vLLM Deployment + Service (validated config)
    └── 20-website-deployment.yaml.tpl   # website Deployment + Service
```

`install.sh` renders every `.tpl` file with `envsubst` using the values you
provide interactively, builds and pushes both Docker images, applies all
manifests directly via `kubectl` (not through ArgoCD sync — see note below),
and generates the Ingress inline based on whether you provide a domain.

## Why manifests are applied directly, not via ArgoCD auto-sync

ArgoCD is installed by this script for optional future GitOps use, but the
actual deployment does **not** depend on ArgoCD syncing successfully. This is
deliberate: `selfHeal: true` sync policies will revert any manual `kubectl
edit`/`patch` you make later (e.g. tuning memory limits or probe timeouts
after observing real behavior on your hardware) back to whatever's in the
chart — which caused exactly that problem during initial validation of this
setup. If you want ArgoCD managing this going forward, point an `Application`
at this repo's `k8s/` folder only after you're confident the manifests here
already reflect your real, working configuration.

## Usage

```bash
curl -sSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh | bash
```

Or clone and run locally:
```bash
git clone https://github.com/<you>/<repo>.git
cd <repo>
./install.sh
```

You'll be prompted for: container registry URL + credentials, the Hugging
Face model ID (+ token if gated), image tags, Kubernetes namespace, resource
requests/limits for the vLLM pod, KV cache size, and optionally a domain name
for the Ingress (leave blank to access via node IP).

## What the script does, in order

1. Preflight checks — git, curl, sudo access, network reachability
   (installs git/curl/Docker automatically if missing; does not proceed on
   unfixable gaps like missing sudo)
2. Installs k3s (skipped if already present)
3. Prompts for all environment-specific values
4. Logs into the container registry
5. Builds + pushes the vLLM model image
6. Builds + pushes the website image
7. Installs ArgoCD (for optional future use — not required for this deploy)
8. Creates the namespace and registry pull secret
9. Renders and applies all Kubernetes manifests
10. Creates the Ingress (with or without a host rule, based on your input)
11. Waits for the vLLM pod to become ready (can take several minutes — CPU
    model warmup is genuinely slow, this is expected, not a hang)
12. Prints the URL to access the chat UI

## Known constraints baked into this config (from real troubleshooting)

- **`TORCHDYNAMO_DISABLE=1`** — required on the CPU vLLM image used here;
  without it, `torch.compile` attempts a C++ kernel build that fails due to
  a missing header in this image's PyTorch install.
- **`strategy: Recreate`** on the vLLM Deployment — a `RollingUpdate` briefly
  runs two replicas, which can fail to schedule on resource-constrained
  single-node clusters (`Insufficient cpu`).
- **`startupProbe` with a 10-minute budget** — CPU inference startup
  (model load + warmup) has been observed taking 3-5 minutes; a shorter
  probe budget kills the pod before it ever finishes starting.
- Memory limits should be sized with real headroom above
  `checkpoint size + VLLM_CPU_KVCACHE_SPACE` — hitting the limit shortly
  after warmup completes (OOMKilled) is a common failure mode if this is
  too tight.
