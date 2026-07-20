#!/usr/bin/env bash
# Phase 0: install the toolchain on the tcow Ubuntu node.
# Idempotent: skips anything already present. Some steps need sudo.
source "$(dirname "$0")/lib.sh"
require_linux

ARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"   # amd64 | arm64
log "host-prep starting (arch=$ARCH)"

install_docker() {
  if command -v docker >/dev/null 2>&1; then ok "docker present"; return; fi
  log "installing Docker Engine"
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl gnupg
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
  warn "added $USER to the docker group — log out/in (or 'newgrp docker') for it to take effect"
}

install_pkgs() {
  log "installing base packages (git, jq, make, iproute2, gnupg)"
  sudo apt-get update -y
  sudo apt-get install -y git jq make iproute2 curl gnupg apt-transport-https
  # yq (mikefarah)
  if ! command -v yq >/dev/null 2>&1; then
    sudo curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" \
      -o /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq
  fi
}

install_go() {
  if command -v go >/dev/null 2>&1; then ok "go present ($(go version))"; return; fi
  log "installing Go ${GO_VERSION}"
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tgz
  sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tgz
  echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' | sudo tee /etc/profile.d/go.sh >/dev/null
  export PATH=$PATH:/usr/local/go/bin
}

install_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then ok "kubectl present"; return; fi
  log "installing kubectl ${KUBECTL_VERSION}"
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl" -o /tmp/kubectl
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
}

install_helm() {
  if command -v helm >/dev/null 2>&1; then ok "helm present"; return; fi
  log "installing helm ${HELM_VERSION}"
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" -o /tmp/helm.tgz
  tar -C /tmp -xzf /tmp/helm.tgz
  sudo install -m 0755 "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm
}

install_kind() {
  if command -v kind >/dev/null 2>&1; then ok "kind present"; return; fi
  log "installing kind ${KIND_VERSION}"
  curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}" -o /tmp/kind
  sudo install -m 0755 /tmp/kind /usr/local/bin/kind
}

install_kwok() {
  if command -v kwokctl >/dev/null 2>&1; then ok "kwokctl present"; return; fi
  log "installing kwok/kwokctl ${KWOK_VERSION}"
  for b in kwok kwokctl; do
    curl -fsSL "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/${b}-linux-${ARCH}" -o "/tmp/$b"
    sudo install -m 0755 "/tmp/$b" "/usr/local/bin/$b"
  done
}

install_clab() {
  if command -v containerlab >/dev/null 2>&1; then ok "containerlab present"; return; fi
  log "installing containerlab ${CLAB_VERSION}"
  bash -c "$(curl -sL https://get.containerlab.dev)" -- -v "${CLAB_VERSION}"
}

install_gnmic() {
  if command -v gnmic >/dev/null 2>&1; then ok "gnmic present"; return; fi
  log "installing gnmic ${GNMIC_VERSION}"
  bash -c "$(curl -sL https://get-gnmic.openconfig.net)" -- -v "${GNMIC_VERSION}"
}

install_docker
install_pkgs
install_go
install_kubectl
install_helm
install_kind
install_kwok
install_clab
install_gnmic

log "pre-pulling heavy images (best-effort)"
docker pull "${SRL_IMAGE}"     2>/dev/null || warn "could not pre-pull ${SRL_IMAGE}"
docker pull kindest/node:${KUBECTL_VERSION} 2>/dev/null || true
docker pull registry.k8s.io/kwok/kwok:${KWOK_VERSION} 2>/dev/null || true

ok "host-prep complete. If you were just added to the docker group, run: newgrp docker"
