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

  while true; do
    read -rp "Hugging Face model ID (e.g. Qwen/Qwen2.5-0.5B-Instruct): " HF_MODEL_ID < /dev/tty
    [[ -n "${HF_MODEL_ID}" ]] && break
    echo "  Cannot be empty."
  done
  read -rsp "Hugging Face token (blank if model is public): " HF_TOKEN < /dev/tty; echo "" < /dev/tty

  read -rp "Image repository path for the model image [base-models/llm]: " VLLM_IMAGE_PATH < /dev/tty
  VLLM_IMAGE_PATH="${VLLM_IMAGE_PATH:-base-models/llm}"
  read -rp "Image tag for the model image [cpu-v1]: " VLLM_IMAGE_TAG < /dev/tty
  VLLM_IMAGE_TAG="${VLLM_IMAGE_TAG:-cpu-v1}"

  read -rp "Image repository path for the website [base-models/chat-website]: " WEBSITE_IMAGE_PATH < /dev/tty
  WEBSITE_IMAGE_PATH="${WEBSITE_IMAGE_PATH:-base-models/chat-website}"
  read -rp "Image tag for the website [v1]: " WEBSITE_IMAGE_TAG < /dev/tty
  WEBSITE_IMAGE_TAG="${WEBSITE_IMAGE_TAG:-v1}"

  read -rp "Kubernetes namespace [llm-demo]: " K8S_NAMESPACE < /dev/tty
  K8S_NAMESPACE="${K8S_NAMESPACE:-llm-demo}"

  read -rp "ACR pull secret name [acr-secret]: " ACR_SECRET_NAME < /dev/tty
  ACR_SECRET_NAME="${ACR_SECRET_NAME:-acr-secret}"

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

  read -rp "Domain name for Ingress (leave blank to use node IP): " DOMAIN_NAME < /dev/tty

  VLLM_IMAGE="${REGISTRY}/${VLLM_IMAGE_PATH}:${VLLM_IMAGE_TAG}"
  WEBSITE_IMAGE="${REGISTRY}/${WEBSITE_IMAGE_PATH}:${WEBSITE_IMAGE_TAG}"

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
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl -n argocd rollout status deploy/argocd-server --timeout=180s \
    && ok "ArgoCD installed" || warn "ArgoCD install had issues — continuing, this doesn't block the deployment"
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
# 9. Render + apply manifests
# ------------------------------------------------------------------------------
apply_manifests() {
  step "Rendering and applying Kubernetes manifests"
  local rendered_dir="${BUILD_DIR}/k8s"
  mkdir -p "${rendered_dir}"

  for tpl in "${SCRIPT_DIR}"/k8s/*.yaml.tpl; do
    local out
    out="${rendered_dir}/$(basename "${tpl}" .tpl)"
    envsubst < "${tpl}" > "${out}"
  done

  kubectl apply -f "${rendered_dir}/namespace.yaml" \
    && kubectl apply -f "${rendered_dir}/vllmdeployment.yaml" \
    && kubectl apply -f "${rendered_dir}/websitedeployment.yaml" \
    && ok "Manifests applied" || fail "Applying manifests failed"
}

# ------------------------------------------------------------------------------
# 10. Ingress
# ------------------------------------------------------------------------------
create_ingress() {
  step "Ingress"
  local ingress_file="${BUILD_DIR}/ingress.yaml"

  if [[ -n "${DOMAIN_NAME}" ]]; then
    cat > "${ingress_file}" << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chat-website-ingress
  namespace: ${K8S_NAMESPACE}
spec:
  rules:
    - host: ${DOMAIN_NAME}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: chat-website-service
                port:
                  number: 80
EOF
  else
    cat > "${ingress_file}" << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: chat-website-ingress
  namespace: ${K8S_NAMESPACE}
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: chat-website-service
                port:
                  number: 80
EOF
  fi

  kubectl apply -f "${ingress_file}" && ok "Ingress created" || fail "Ingress creation failed"
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
  apply_manifests
  create_ingress
  wait_for_vllm
  print_summary
}

main
