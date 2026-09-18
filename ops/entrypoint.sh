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
# SSH sessions reset PATH; make the nix profile tools available.
SetEnv PATH=/root/.nix-profile/bin:/usr/bin:/bin
EOF
fi

# sshd also requires its privilege-separation user, which no container image
# ships in /etc/passwd.
if ! grep -q '^sshd:' /etc/passwd; then
  echo 'sshd:x:74:74:Privilege-separated SSH:/var/empty/sshd:/sbin/nologin' >> /etc/passwd
  mkdir -p /var/empty/sshd
fi

# OpenSSH 9.8+ treats 'root:x:...' (no shadow) and empty-password accounts as
# LOCKED ("User root not allowed because account is locked"). Rewrite root's
# entry unconditionally with a static throwaway hash (mkpasswd -m sha-512;
# PasswordAuthentication=no means it can never be used). Single-quoted so the
# shell doesn't expand $6$...; python3 crypt is gone in 3.13, hence static.
HASH='$6$7JlBtOCF/x/eVzh7$N/n/EWQ6.VtS87YcLgJ7WI5gLcFpSLGKIo81jdJdBA9oAf7bEVHVWd6K42vcedYUDekt4MBzCeUjalNjo3vV5.'
# ...and the image has no /bin/bash (nix bash lives in the store) - sshd
# rejects users whose shell doesn't exist. Resolve the real bash at runtime.
SHELL_PATH=$(command -v bash 2>/dev/null || echo /bin/sh)
grep -v '^root:' /etc/passwd > /tmp/passwd.new
echo "root:$HASH:0:0:root:/root:$SHELL_PATH" >> /tmp/passwd.new
mv /tmp/passwd.new /etc/passwd

# Shadow-aware sshd (USE_SHADOW) ignores pw_passwd and uses getspnam() - and
# this image's /etc/shadow is a READ-ONLY store symlink whose root entry is
# LOCKED ('!') -> "User root not allowed because account is locked". Replace
# the symlink unconditionally with a real file carrying root's throwaway hash
# (+ sshd user, locked is fine for the privsep user).
rm -f /etc/shadow
echo "root:$HASH:19000:0:99999:7:::" > /etc/shadow
echo "sshd:*:19000:0:99999:7:::" >> /etc/shadow
chmod 640 /etc/shadow
chown root:shadow /etc/shadow 2>/dev/null || chown root:root /etc/shadow

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
