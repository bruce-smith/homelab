# Cluster ops toolkit image - everything needed to manage the homelab from
# inside the cluster, so the main PC is no longer required as a bridge.
#
# Contents: kubectl, helm, helmfile, sops, age, git, openssh (client+server),
# curl, jq, python3, and Nix itself (the nixos/nix base) so nixos-anywhere can
# be run on demand via `nix run github:nix-community/nixos-anywhere`.
#
# Build (on the PC):  docker build -t homelab/cluster-ops:latest ops/
# Distribute:         docker save homelab/cluster-ops:latest -o ops.tar
#                     scp ops.tar node0: && ssh node0 ctr -n k8s.io images import ops.tar
FROM nixos/nix:latest

# All tools via the Nix package manager (single source, reproducible).
# openssh ships sshd + ssh; python3 for helper scripts; bash is the shell.
RUN nix profile install \
      nixpkgs#kubectl \
      nixpkgs#helm \
      nixpkgs#helmfile \
      nixpkgs#sops \
      nixpkgs#age \
      nixpkgs#git \
      nixpkgs#openssh \
      nixpkgs#curl \
      nixpkgs#jq \
      nixpkgs#python3 \
      nixpkgs#bash

# The Hermes pod's public key - the only client allowed to log in. This is a
# PUBLIC key (safe in the repo); the private half stays in /opt/data/.ssh on
# the Hermes pod's persistent volume.
COPY authorized_keys /root/.ssh/authorized_keys
RUN chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
