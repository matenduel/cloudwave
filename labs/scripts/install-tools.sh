#!/usr/bin/env bash
# bash/arm64 기준, CMD 미확인 — install-tools.cmd bash 등가 스크립트.
# darwin/arm64 바이너리만 받는다(이 하네스가 Apple Silicon 맥이기 때문).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BIN_DIR="$LAB_ROOT/bin"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$BIN_DIR"

echo "Installing kind $KIND_VERSION to $BIN_DIR/kind"
curl -fsSL -o "$BIN_DIR/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-darwin-arm64"
chmod +x "$BIN_DIR/kind"

echo "Installing kubectl $KUBECTL_VERSION to $BIN_DIR/kubectl"
curl -fsSL -o "$BIN_DIR/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/darwin/arm64/kubectl"
chmod +x "$BIN_DIR/kubectl"

echo "Installing helm $HELM_VERSION to $BIN_DIR/helm"
curl -fsSL -o "$TMP_DIR/helm.tar.gz" "https://get.helm.sh/helm-${HELM_VERSION}-darwin-arm64.tar.gz"
tar -xzf "$TMP_DIR/helm.tar.gz" -C "$TMP_DIR"
cp "$TMP_DIR/darwin-arm64/helm" "$BIN_DIR/helm"
chmod +x "$BIN_DIR/helm"

echo
echo "Installed tools:"
"$BIN_DIR/kind" version
"$BIN_DIR/kubectl" version --client=true
"$BIN_DIR/helm" version --short
