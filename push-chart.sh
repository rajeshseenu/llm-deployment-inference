#!/usr/bin/env bash
# ==============================================================================
# push-chart.sh — package + push a new chart version to ACR.
#
# Run this after editing helm/llm-chat-stack/values.yaml (e.g. bumping
# vllm.image.tag to a new model image you've built and pushed). ArgoCD
# (configured with targetRevision: "*") picks up the new version
# automatically — no other steps needed.
#
# Usage: ./push-chart.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/helm/llm-chat-stack"

read -rp "Registry login server (e.g. myregistry.azurecr.io): " REGISTRY
read -rp "Registry username: " REGISTRY_USER
read -rsp "Registry password: " REGISTRY_PASS; echo ""

CHART_VERSION="0.1.$(date +%s)"
sed -i "s/^version: .*/version: ${CHART_VERSION}/" "${CHART_DIR}/Chart.yaml"

echo "==> Packaging chart version ${CHART_VERSION}"
helm package "${CHART_DIR}" -d /tmp

echo "==> Logging into ${REGISTRY}"
helm registry login "${REGISTRY}" --username "${REGISTRY_USER}" --password "${REGISTRY_PASS}"

echo "==> Pushing to oci://${REGISTRY}/helm"
helm push "/tmp/llm-chat-stack-${CHART_VERSION}.tgz" "oci://${REGISTRY}/helm"

echo ""
echo "==> Done. ArgoCD will pick up version ${CHART_VERSION} automatically"
echo "    (typically within its default polling interval, or force it with:"
echo "    kubectl -n argocd patch application llm-chat-stack --type merge -p '{\"operation\":{\"sync\":{}}}')"
