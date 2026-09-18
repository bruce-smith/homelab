#!/bin/sh
# Cluster-ops entrypoint: build an in-cluster kubeconfig from the ServiceAccount,
# clone the homelab repo, then serve sshd so the Hermes pod can run tools here.
set -e

export PATH="/root/.nix-profile/bin:$PATH"

# --- sshd host keys (generated once per pod start; ephemeral is fine) ---
mkdir -p /etc/ssh /run/sshd
ssh-keygen -A 2>/dev/null || true

# The nixos/nix base image ships openssh but no /etc/ssh/sshd_config - sshd
# refuses to start without one.
if [ ! -f /etc/ssh/sshd_config ]; then
  cat > /etc/ssh/sshd_config <<'EOF'
Port 22
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
AuthorizedKeysFile .ssh/authorized_keys
EOF
fi

# --- kubeconfig from the in-cluster ServiceAccount token ---
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
  SA_DIR=/var/run/secrets/kubernetes.io/serviceaccount
  mkdir -p /root/.kube
  cat > /root/.kube/config <<EOF
apiVersion: v1
kind: Config
clusters:
  - cluster:
      certificate-authority: $SA_DIR/ca.crt
      server: https://kubernetes.default.svc
    name: in-cluster
contexts:
  - context:
      cluster: in-cluster
      user: ops-sa
    name: in-cluster
current-context: in-cluster
users:
  - name: ops-sa
    user:
      token: $(cat $SA_DIR/token)
EOF
  chmod 600 /root/.kube/config
  echo "[ops] kubeconfig ready (in-cluster SA)"
else
  echo "[ops] WARNING: no ServiceAccount token - kubectl/helm/helmfile need a kubeconfig"
fi

# --- homelab repo (public GitHub - no creds needed) ---
mkdir -p /work
if [ ! -d /work/homelab/.git ]; then
  git clone --quiet https://github.com/bruce-smith/homelab /work/homelab || echo "[ops] clone failed"
else
  git -C /work/homelab pull --quiet || echo "[ops] pull failed"
fi

echo "[ops] cluster-ops ready - sshd listening on :22"
exec /root/.nix-profile/bin/sshd -D -e
