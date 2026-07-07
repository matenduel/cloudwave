#!/usr/bin/env bash
# kind/kubectl/helm/amtool 설치 스크립트 (macOS/Linux, install-tools.cmd 등가).
# OS는 uname -s로, 아키텍처는 인자(amd64|arm64) 또는 uname -m으로 자동 감지한다.
# 이미 설치된 바이너리가 있으면 건드리지 않는다(idempotent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../VERSIONS.env"

BIN_DIR="${BIN_DIR:-$HOME/aiops-tools}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$BIN_DIR"

case "$(uname -s)" in
  Darwin) OS="darwin" ;;
  Linux) OS="linux" ;;
  *) echo "지원하지 않는 OS입니다: $(uname -s) (macOS 또는 Linux에서 실행하세요)" >&2; exit 1 ;;
esac

ARCH="${1:-}"
if [ -z "$ARCH" ]; then
  case "$(uname -m)" in
    arm64|aarch64) ARCH="arm64" ;;
    x86_64|amd64) ARCH="amd64" ;;
    *) echo "지원하지 않는 아키텍처입니다: $(uname -m) (amd64 또는 arm64를 인자로 지정하세요)" >&2; exit 1 ;;
  esac
fi
case "$ARCH" in
  amd64|arm64) ;;
  *) echo "아키텍처는 amd64 또는 arm64만 지원합니다: $ARCH" >&2; exit 1 ;;
esac

echo "OS/아키텍처: $OS/$ARCH (설치 위치: $BIN_DIR)"

command -v curl >/dev/null 2>&1 || { echo "curl이 필요합니다." >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar가 필요합니다." >&2; exit 1; }

echo "Installing kind $KIND_VERSION to $BIN_DIR/kind"
if [ -x "$BIN_DIR/kind" ]; then
  echo "kind already exists; keeping existing binary."
else
  curl -fsSL -o "$BIN_DIR/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}"
  chmod +x "$BIN_DIR/kind"
fi

echo "Installing kubectl $KUBECTL_VERSION to $BIN_DIR/kubectl"
if [ -x "$BIN_DIR/kubectl" ]; then
  echo "kubectl already exists; keeping existing binary."
else
  curl -fsSL -o "$BIN_DIR/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
  chmod +x "$BIN_DIR/kubectl"
fi

echo "Installing helm $HELM_VERSION to $BIN_DIR/helm"
if [ -x "$BIN_DIR/helm" ]; then
  echo "helm already exists; keeping existing binary."
else
  curl -fsSL -o "$TMP_DIR/helm.tar.gz" "https://get.helm.sh/helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
  tar -xzf "$TMP_DIR/helm.tar.gz" -C "$TMP_DIR"
  cp "$TMP_DIR/${OS}-${ARCH}/helm" "$BIN_DIR/helm"
  chmod +x "$BIN_DIR/helm"
fi

echo "Installing amtool $AMTOOL_VERSION to $BIN_DIR/amtool"
if [ -x "$BIN_DIR/amtool" ]; then
  echo "amtool already exists; keeping existing binary."
else
  curl -fsSL -o "$TMP_DIR/alertmanager.tar.gz" "https://github.com/prometheus/alertmanager/releases/download/v${AMTOOL_VERSION}/alertmanager-${AMTOOL_VERSION}.${OS}-${ARCH}.tar.gz"
  tar -xzf "$TMP_DIR/alertmanager.tar.gz" -C "$TMP_DIR"
  cp "$TMP_DIR/alertmanager-${AMTOOL_VERSION}.${OS}-${ARCH}/amtool" "$BIN_DIR/amtool"
  chmod +x "$BIN_DIR/amtool"
fi

echo
echo "Installed tools:"
"$BIN_DIR/kind" version
"$BIN_DIR/kubectl" version --client=true
"$BIN_DIR/helm" version --short
"$BIN_DIR/amtool" --version

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    echo "PATH에 $BIN_DIR 가 없습니다. 현재 셸에 바로 반영하려면:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
    echo "새 터미널에서도 유지하려면 ~/.zshrc(또는 ~/.bashrc)에 같은 줄을 추가하세요."
    ;;
esac
