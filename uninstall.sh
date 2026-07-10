#!/usr/bin/env bash
# ==============================================================================
# uninstall.sh — tears down what install.sh sets up.
#
# Two modes:
#   1) App only    — removes the Kubernetes namespace (vLLM + website + Ingress)
#                    and the ArgoCD namespace. Leaves k3s/Docker/git installed.
#   2) Everything  — the above, PLUS completely removes k3s and Docker
#                    (purged, not just stopped) and uninstalls git.
#                    Leaves the machine as close to "nothing installed" as
#                    this script can manage, for a genuinely clean re-test
#                    of install.sh from scratch.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/<you>/<repo>/main/uninstall.sh | bash
# ==============================================================================

set -uo pipefail   # deliberately NOT -e — teardown should keep going even if
                    # individual steps fail (e.g. resource already gone)

ok()   { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }
step() { echo ""; echo "==> $1"; }

# ------------------------------------------------------------------------------
# Mode selection
# ------------------------------------------------------------------------------
echo "What do you want to remove?"
echo "  1) App only — Kubernetes resources (namespace, ArgoCD). Keeps k3s/Docker/git installed."
echo "  2) Everything — app resources AND k3s, Docker, git themselves"
read -rp "Enter 1 or 2 [1]: " MODE < /dev/tty
MODE="${MODE:-1}"

read -rp "Kubernetes namespace to remove [llm-demo]: " K8S_NAMESPACE < /dev/tty
K8S_NAMESPACE="${K8S_NAMESPACE:-llm-demo}"

# ------------------------------------------------------------------------------
# App resources — always removed, both modes
# ------------------------------------------------------------------------------
remove_app_resources() {
  step "Removing app resources"

  if command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
    kubectl delete namespace "${K8S_NAMESPACE}" --ignore-not-found=true --timeout=60s \
      && ok "Namespace ${K8S_NAMESPACE} removed" \
      || warn "Namespace ${K8S_NAMESPACE} removal had issues (may already be gone)"

    kubectl delete namespace argocd --ignore-not-found=true --timeout=60s \
      && ok "ArgoCD namespace removed" \
      || warn "ArgoCD namespace removal had issues (may already be gone)"
  else
    warn "kubectl not reachable — skipping Kubernetes resource cleanup (cluster may already be gone)"
  fi
}

# ------------------------------------------------------------------------------
# Full dependency removal — mode 2 only
# ------------------------------------------------------------------------------
remove_k3s() {
  step "Removing k3s"
  if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    sudo /usr/local/bin/k3s-uninstall.sh && ok "k3s uninstalled" || warn "k3s-uninstall.sh reported issues"
  else
    warn "k3s-uninstall.sh not found — k3s may not be installed, skipping"
  fi
  rm -rf ~/.kube
  sed -i '/KUBECONFIG=~\/.kube\/config/d' ~/.bashrc 2>/dev/null || true
  ok "kubeconfig cleaned up"
}

remove_docker() {
  step "Removing Docker"
  if command -v docker >/dev/null 2>&1; then
    sudo systemctl stop docker 2>/dev/null || true
    sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker-model-plugin >/dev/null 2>&1
    sudo apt-get autoremove -y --purge >/dev/null 2>&1
    sudo rm -rf /var/lib/docker /var/lib/containerd /etc/docker
    sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
    sudo groupdel docker 2>/dev/null || true
    ok "Docker removed"
  else
    warn "Docker not found — skipping"
  fi
}

remove_git() {
  step "Removing git"
  if command -v git >/dev/null 2>&1; then
    sudo apt-get purge -y git >/dev/null 2>&1
    sudo apt-get autoremove -y --purge >/dev/null 2>&1
    ok "git removed"
  else
    warn "git not found — skipping"
  fi
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
remove_app_resources

if [[ "${MODE}" == "2" ]]; then
  remove_k3s
  remove_docker
  remove_git
fi

echo ""
echo "==> Teardown complete."
if [[ "${MODE}" == "2" ]]; then
  echo "Machine is back to a near-clean state. Re-run install.sh to test a fresh install."
else
  echo "App resources removed. k3s/Docker/git left installed."
fi
