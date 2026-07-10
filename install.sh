#!/usr/bin/env bash
# ==============================================================================
# install.sh — end-to-end installer for the LLM chat stack (vLLM CPU + website)
#
# Order of operations:
#   1. Preflight checks (installs missing prerequisites where possible)
#   2. Install k3s (skipped if already present)
#   3. Prompt for all environment-specific values (nothing hardcoded)
#   4. Log into the container registry
#   5. Build + push the vLLM model image
#   6. Build + push the website image
#   7. Install ArgoCD (optional future GitOps use — not required for this deploy)
#   8. Create namespace + registry pull secret
#   9. Render + apply all Kubernetes manifests
#  10. Create the Ingress
#  11. Wait for vLLM to become ready
#  12. Print the access URL
#
# Fresh-install only: does not attempt to detect or reconcile an existing
# deployment's drift. Re-running against an already-deployed system may
# recreate resources.
# ==============================================================================

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/rajeshseenu/llm-deployment-inference.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
export REPO_URL REPO_BRANCH
BUILD_DIR="$(mktemp -d /tmp/llm-chat-install.XXXXXX)"
SCRIPT_DIR=""   # set by clone_repo(), used by every build/render step below

ok()   { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }
fail() { echo "❌ $1"; exit 1; }
step() { echo ""; echo "==> $1"; }

trap 'rm -rf "${BUILD_DIR}"' EXIT

# ------------------------------------------------------------------------------
# 0. Clone this repo into a throwaway temp dir — makes the script runnable
#    standalone via: curl -sSL <raw-url>/install.sh | bash
# ------------------------------------------------------------------------------
clone_repo() {
  step "Fetching repo: ${REPO_URL}"
  local clone_dir="${BUILD_DIR}/repo"
  git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${clone_dir}" \
    && ok "Repo cloned" || fail "git clone failed — check REPO_URL and network"
  SCRIPT_DIR="${clone_dir}"
}

# ------------------------------------------------------------------------------
# 1. Preflight checks
# ------------------------------------------------------------------------------
preflight() {
  step "Preflight checks"

  if sudo -n true 2>/dev/null || sudo -v 2>/dev/null; then
    ok "Sudo access available"
  else
    fail "Sudo access not available — required for installing k3s/Docker"
  fi

  if command -v curl >/dev/null 2>&1; then
    ok "curl installed"
  else
    warn "curl not found — installing..."
    sudo apt-get update -qq && sudo apt-get install -y -qq curl \
      && ok "curl installed" || fail "curl installation failed"
  fi

  if command -v git >/dev/null 2>&1; then
    ok "git installed ($(git --version | awk '{print $3}'))"
  else
    warn "git not found — installing..."
    sudo apt-get update -qq && sudo apt-get install -y -qq git \
      && ok "git installed" || fail "git installation failed"
  fi

  if command -v docker >/dev/null 2>&1; then
    ok "Docker installed ($(docker --version | awk '{print $3}' | tr -d ','))"
  else
    warn "Docker not found — installing..."
    curl -fsSL https://get.docker.com | sh \
      && sudo systemctl enable --now docker 2>/dev/null \
      && ok "Docker installed" || fail "Docker installation failed"
  fi

  if command -v envsubst >/dev/null 2>&1; then
    ok "envsubst installed"
  else
    warn "envsubst not found — installing (gettext-base)..."
    sudo apt-get update -qq && sudo apt-get install -y -qq gettext-base \
      && ok "envsubst installed" || fail "envsubst installation failed"
  fi

  if command -v python3 >/dev/null 2>&1; then
    ok "python3 installed"
  else
    warn "python3 not found — installing..."
    sudo apt-get update -qq && sudo apt-get install -y -qq python3 \
      && ok "python3 installed" || fail "python3 installation failed"
  fi

  if command -v helm >/dev/null 2>&1; then
    ok "helm installed ($(helm version --short 2>/dev/null))"
  else
    warn "helm not found — installing..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
      && ok "helm installed" || fail "helm installation failed"
  fi

  if curl -fsS --max-time 5 https://github.com >/dev/null 2>&1; then
    ok "Network reachable: github.com"
  else
    fail "Cannot reach github.com — check network/DNS"
  fi
}

# ------------------------------------------------------------------------------
# 2. Install k3s
# ------------------------------------------------------------------------------
install_k3s() {
  step "Kubernetes (k3s)"
  if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
    ok "k3s already installed and reachable"
    return
  fi
  curl -sfL https://get.k3s.io | sh - || fail "k3s installation failed"
  mkdir -p ~/.kube
  sudo k3s kubectl config view --raw > ~/.kube/config
  chmod 600 ~/.kube/config
  export KUBECONFIG=~/.kube/config
  if ! grep -q "KUBECONFIG=~/.kube/config" ~/.bashrc 2>/dev/null; then
    echo 'export KUBECONFIG=~/.kube/config' >> ~/.bashrc
  fi
  kubectl get nodes && ok "k3s installed and reachable" || fail "k3s installed but kubectl cannot reach it"
}

# ------------------------------------------------------------------------------
# 3. Prompt for all values
# ------------------------------------------------------------------------------
collect_inputs() {
  step "Configuration (nothing below is saved to disk)"

  read -rp "Container registry login server (e.g. myregistry.azurecr.io): " REGISTRY < /dev/tty
  read -rp "Registry username: " REGISTRY_USER < /dev/tty
  read -rsp "Registry password: " REGISTRY_PASS < /dev/tty; echo "" < /dev/tty

  read -rp "Hugging Face model ID [Qwen/Qwen2.5-0.5B-Instruct]: " HF_MODEL_ID < /dev/tty
  HF_MODEL_ID="${HF_MODEL_ID:-Qwen/Qwen2.5-0.5B-Instruct}"
  read -rsp "Hugging Face token (blank if model is public): " HF_TOKEN < /dev/tty; echo "" < /dev/tty

  # Single combined image:tag prompt instead of two separate prompts each
  read -rp "Model image name:tag (e.g. base-models/qwen2.5-0.5b-instruct:cpu-v3) [base-models/qwen2.5-0.5b-instruct:cpu-v3]: " VLLM_IMAGE_REF < /dev/tty
  VLLM_IMAGE_REF="${VLLM_IMAGE_REF:-base-models/qwen2.5-0.5b-instruct:cpu-v3}"

  read -rp "Website image name:tag (e.g. base-models/chat-website:v1) [base-models/chat-website:v1]: " WEBSITE_IMAGE_REF < /dev/tty
  WEBSITE_IMAGE_REF="${WEBSITE_IMAGE_REF:-base-models/chat-website:v1}"

  read -rp "Kubernetes namespace [llm-demo]: " K8S_NAMESPACE < /dev/tty
  K8S_NAMESPACE="${K8S_NAMESPACE:-llm-demo}"

  # ACR pull secret name is no longer asked — generated automatically.
  ACR_SECRET_NAME="acr-secret"

  echo ""
  echo "Resource sizing for the vLLM pod:"
  echo "  1) Use defaults (2 vCPU request / 4 vCPU limit, 5Gi/9Gi memory, 2GB KV cache)"
  echo "  2) Customize"
  read -rp "Enter 1 or 2 [1]: " RESOURCE_CHOICE < /dev/tty
  RESOURCE_CHOICE="${RESOURCE_CHOICE:-1}"

  if [[ "${RESOURCE_CHOICE}" == "2" ]]; then
    read -rp "vLLM CPU request [2]: " VLLM_CPU_REQUEST < /dev/tty
    VLLM_CPU_REQUEST="${VLLM_CPU_REQUEST:-2}"
    read -rp "vLLM CPU limit [4]: " VLLM_CPU_LIMIT < /dev/tty
    VLLM_CPU_LIMIT="${VLLM_CPU_LIMIT:-4}"
    read -rp "vLLM memory request [5Gi]: " VLLM_MEM_REQUEST < /dev/tty
    VLLM_MEM_REQUEST="${VLLM_MEM_REQUEST:-5Gi}"
    read -rp "vLLM memory limit [9Gi]: " VLLM_MEM_LIMIT < /dev/tty
    VLLM_MEM_LIMIT="${VLLM_MEM_LIMIT:-9Gi}"
    read -rp "vLLM KV cache size in GB [2]: " VLLM_KVCACHE_GB < /dev/tty
    VLLM_KVCACHE_GB="${VLLM_KVCACHE_GB:-2}"
  else
    VLLM_CPU_REQUEST="2"
    VLLM_CPU_LIMIT="4"
    VLLM_MEM_REQUEST="5Gi"
    VLLM_MEM_LIMIT="9Gi"
    VLLM_KVCACHE_GB="2"
    ok "Using default resource sizing"
  fi

  read -rp "Domain name for Ingress (leave blank to use node IP): " DOMAIN_NAME < /dev/tty

  VLLM_IMAGE="${REGISTRY}/${VLLM_IMAGE_REF}"
  WEBSITE_IMAGE="${REGISTRY}/${WEBSITE_IMAGE_REF}"

  export REGISTRY REGISTRY_USER REGISTRY_PASS HF_MODEL_ID HF_TOKEN
  export VLLM_IMAGE WEBSITE_IMAGE K8S_NAMESPACE ACR_SECRET_NAME
  export VLLM_CPU_REQUEST VLLM_CPU_LIMIT VLLM_MEM_REQUEST VLLM_MEM_LIMIT VLLM_KVCACHE_GB
  export DOMAIN_NAME
}

# ------------------------------------------------------------------------------
# 4. Registry login
# ------------------------------------------------------------------------------
registry_login() {
  step "Registry login: ${REGISTRY}"
  echo "${REGISTRY_PASS}" | docker login "${REGISTRY}" --username "${REGISTRY_USER}" --password-stdin \
    && ok "Logged into ${REGISTRY}" || fail "Registry login failed"
}

# ------------------------------------------------------------------------------
# 5. Build + push vLLM image
# ------------------------------------------------------------------------------
build_vllm_image() {
  step "Building vLLM model image: ${VLLM_IMAGE}"
  DOCKER_BUILDKIT=1 docker build -f "${SCRIPT_DIR}/vllm/Dockerfile.cpu" \
    --secret id=hf_token,env=HF_TOKEN \
    --build-arg HF_MODEL_ID="${HF_MODEL_ID}" \
    -t "${VLLM_IMAGE}" \
    "${SCRIPT_DIR}/vllm" \
    && ok "Built ${VLLM_IMAGE}" || fail "vLLM image build failed"

  docker push "${VLLM_IMAGE}" && ok "Pushed ${VLLM_IMAGE}" || fail "vLLM image push failed"
}

# ------------------------------------------------------------------------------
# 6. Build + push website image
# ------------------------------------------------------------------------------
build_website_image() {
  step "Building website image: ${WEBSITE_IMAGE}"
  local website_build_dir="${BUILD_DIR}/website"
  mkdir -p "${website_build_dir}"
  cp "${SCRIPT_DIR}/website/index.html" "${website_build_dir}/"
  cp "${SCRIPT_DIR}/website/app.js" "${website_build_dir}/"
  cp "${SCRIPT_DIR}/website/Dockerfile" "${website_build_dir}/"

  # Render nginx.conf.tpl — explicitly list K8S_NAMESPACE so envsubst leaves
  # nginx's own $host variable untouched.
  envsubst '${K8S_NAMESPACE}' < "${SCRIPT_DIR}/website/nginx.conf.tpl" > "${website_build_dir}/nginx.conf"

  docker build -t "${WEBSITE_IMAGE}" "${website_build_dir}" \
    && ok "Built ${WEBSITE_IMAGE}" || fail "Website image build failed"

  docker push "${WEBSITE_IMAGE}" && ok "Pushed ${WEBSITE_IMAGE}" || fail "Website image push failed"
}

# ------------------------------------------------------------------------------
# 7. Install ArgoCD (optional future use, not required for this deploy)
# ------------------------------------------------------------------------------
install_argocd() {
  step "ArgoCD (installed for optional future GitOps use)"
  if kubectl get namespace argocd >/dev/null 2>&1; then
    ok "ArgoCD namespace already exists — skipping install"
    return
  fi
  kubectl create namespace argocd || true

  # --server-side avoids kubectl's client-side "last-applied-configuration"
  # annotation, which is too large for some ArgoCD CRDs (ApplicationSet) and
  # otherwise causes a hard failure here.
  if kubectl apply -n argocd --server-side --force-conflicts \
       -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml; then
    kubectl -n argocd rollout status deploy/argocd-server --timeout=180s \
      && ok "ArgoCD installed" || warn "ArgoCD server not ready yet — continuing, this doesn't block the deployment"
  else
    warn "ArgoCD install had errors — continuing anyway, since it's optional and not required for this deployment"
  fi
}

# ------------------------------------------------------------------------------
# 8. Namespace + registry pull secret
# ------------------------------------------------------------------------------
create_namespace_and_secret() {
  step "Namespace + registry pull secret"
  kubectl create namespace "${K8S_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  ok "Namespace ${K8S_NAMESPACE} ready"

  kubectl -n "${K8S_NAMESPACE}" delete secret "${ACR_SECRET_NAME}" --ignore-not-found=true >/dev/null 2>&1
  kubectl -n "${K8S_NAMESPACE}" create secret docker-registry "${ACR_SECRET_NAME}" \
    --docker-server="${REGISTRY}" \
    --docker-username="${REGISTRY_USER}" \
    --docker-password="${REGISTRY_PASS}" \
    && ok "Registry pull secret created" || fail "Failed to create registry pull secret"
}

# ------------------------------------------------------------------------------
# 9. Update values.yaml locally, then package + push the Helm chart to ACR as
#    an OCI artifact. This is the only place values.yaml is edited — this
#    repo's git copy is left untouched; the chart in ACR is what ArgoCD reads.
# ------------------------------------------------------------------------------
package_and_push_chart() {
  step "Preparing Helm chart"
  local chart_src="${SCRIPT_DIR}/helm/llm-chat-stack"
  local chart_build="${BUILD_DIR}/chart/llm-chat-stack"
  mkdir -p "$(dirname "${chart_build}")"
  cp -r "${chart_src}" "${chart_build}"

  local values_file="${chart_build}/values.yaml"
  local vllm_repo="${VLLM_IMAGE%:*}"
  local vllm_tag="${VLLM_IMAGE##*:}"

  python3 - "$values_file" "$K8S_NAMESPACE" "$vllm_repo" "$vllm_tag" "$VLLM_KVCACHE_GB" \
    "$VLLM_CPU_REQUEST" "$VLLM_CPU_LIMIT" "$VLLM_MEM_REQUEST" "$VLLM_MEM_LIMIT" \
    "$WEBSITE_IMAGE" "$ACR_SECRET_NAME" "$DOMAIN_NAME" << 'PYEOF'
import sys, re
path, ns, vrepo, vtag, kv, cpureq, cpulim, memreq, memlim, website_img, secret, host = sys.argv[1:13]
with open(path) as f:
    content = f.read()
content = re.sub(r'namespace: .*', f'namespace: {ns}', content, count=1)
content = re.sub(r'repository: .*azurecr\.io/base-models/qwen.*', f'repository: {vrepo}', content, count=1)
content = re.sub(r'(\n  tag: ).*', rf'\g<1>{vtag}', content, count=1)
content = re.sub(r'kvCacheSpaceGB: .*', f'kvCacheSpaceGB: {kv}', content, count=1)
content = re.sub(r'(requests:\n      cpu: ").*(")', rf'\g<1>{cpureq}\g<2>', content, count=1)
content = re.sub(r'(limits:\n      cpu: ").*(")', rf'\g<1>{cpulim}\g<2>', content, count=1)
content = re.sub(r'(requests:\n      cpu: "[^"]*"\n      memory: ").*(")', rf'\g<1>{memreq}\g<2>', content, count=1)
content = re.sub(r'(limits:\n      cpu: "[^"]*"\n      memory: ").*(")', rf'\g<1>{memlim}\g<2>', content, count=1)
content = re.sub(r'(website:\n  image: ).*', rf'\g<1>{website_img}', content, count=1)
content = re.sub(r'(name: ).*(   # created directly)', rf'\g<1>{secret}\g<2>', content, count=1)
content = re.sub(r'(host: )".*"', rf'\g<1>"{host}"', content, count=1)
with open(path, 'w') as f:
    f.write(content)
PYEOF
  ok "values.yaml prepared with your inputs"

  # Version each push uniquely — OCI charts are immutable per version, so a
  # timestamp guarantees this install (and any later manual push) never
  # collides with a previous one.
  CHART_VERSION="0.1.$(date +%s)"
  sed -i "s/^version: .*/version: ${CHART_VERSION}/" "${chart_build}/Chart.yaml"
  export CHART_VERSION

  step "Packaging chart version ${CHART_VERSION}"
  helm package "${chart_build}" -d "${BUILD_DIR}" && ok "Chart packaged" || fail "helm package failed"

  step "Pushing chart to ${REGISTRY}/helm"
  helm registry login "${REGISTRY}" --username "${REGISTRY_USER}" --password "${REGISTRY_PASS}" \
    && ok "Logged into ${REGISTRY} for Helm" || fail "Helm registry login failed"

  helm push "${BUILD_DIR}/llm-chat-stack-${CHART_VERSION}.tgz" "oci://${REGISTRY}/helm" \
    && ok "Pushed chart ${CHART_VERSION} to oci://${REGISTRY}/helm" || fail "helm push failed"
}

# ------------------------------------------------------------------------------
# 10. Give ArgoCD OCI registry credentials, then deploy the Application.
#     targetRevision uses a semver wildcard ("*") — any later chart version
#     you push to ACR is picked up automatically without touching this
#     Application again.
# ------------------------------------------------------------------------------
deploy_argocd_application() {
  step "Configuring ArgoCD's access to the OCI Helm registry"
  kubectl -n argocd delete secret acr-helm-repo --ignore-not-found=true >/dev/null 2>&1
  kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: acr-helm-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  name: acr-helm
  url: ${REGISTRY}/helm
  enableOCI: "true"
  username: ${REGISTRY_USER}
  password: ${REGISTRY_PASS}
EOF
  ok "ArgoCD OCI repo credentials configured"

  step "Deploying ArgoCD Application"
  local app_file="${BUILD_DIR}/application.yaml"
  export K8S_NAMESPACE
  envsubst '${REGISTRY} ${K8S_NAMESPACE}' \
    < "${SCRIPT_DIR}/argocd/application.yaml.tpl" > "${app_file}"

  kubectl apply -f "${app_file}" && ok "ArgoCD Application created" || fail "Failed to create ArgoCD Application"

  sleep 3
  kubectl -n argocd patch application llm-chat-stack --type merge \
    -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}' >/dev/null 2>&1 || true
  sleep 3
  kubectl -n argocd patch application llm-chat-stack --type merge \
    -p '{"operation":{"sync":{}}}' >/dev/null 2>&1 || true
  ok "Sync triggered"
}

# ------------------------------------------------------------------------------
# 11. Wait for vLLM readiness
# ------------------------------------------------------------------------------
wait_for_vllm() {
  step "Waiting for vLLM to become ready (this can take several minutes on CPU — normal, not a hang)"
  if kubectl -n "${K8S_NAMESPACE}" wait --for=condition=ready pod -l app=vllm-server --timeout=600s; then
    ok "vLLM is ready"
  else
    warn "vLLM did not become ready within 10 minutes — check: kubectl -n ${K8S_NAMESPACE} logs -f deploy/vllm-server"
  fi
}

# ------------------------------------------------------------------------------
# 12. Final output
# ------------------------------------------------------------------------------
print_summary() {
  step "Done"
  local node_ip
  node_ip="$(hostname -I | awk '{print $1}')"
  echo "Namespace:      ${K8S_NAMESPACE}"
  echo "vLLM image:     ${VLLM_IMAGE}"
  echo "Website image:  ${WEBSITE_IMAGE}"
  if [[ -n "${DOMAIN_NAME}" ]]; then
    echo "Access the chat UI at: http://${DOMAIN_NAME}/"
  else
    echo "Access the chat UI at: http://${node_ip}/"
  fi
  echo ""
  echo "Check status any time with:"
  echo "  kubectl -n ${K8S_NAMESPACE} get pods"
  echo "  kubectl -n ${K8S_NAMESPACE} logs -f deploy/vllm-server"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
  preflight
  clone_repo
  install_k3s
  collect_inputs
  registry_login
  build_vllm_image
  build_website_image
  install_argocd
  create_namespace_and_secret
  package_and_push_chart
  deploy_argocd_application
  wait_for_vllm
  print_summary
}

main
