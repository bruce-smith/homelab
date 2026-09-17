#!/bin/sh
# Build the cluster-ops image on the PC and import it into the nodes.
# Usage (from the homelab repo root on the PC):
#   sh ops/build-and-import.sh
set -e
IMAGE=homelab/cluster-ops:latest
TAR=ops.tar

echo "==> building $IMAGE (PC Docker Desktop)"
docker build -t "$IMAGE" ops/

echo "==> saving + importing into node0"
docker save "$IMAGE" -o "$TAR"
scp "$TAR" node0:/tmp/ops.tar
ssh node0 "sudo ctr -n k8s.io images import /tmp/ops.tar && rm /tmp/ops.tar"

echo "==> done. Deployment (helm/charts/ops) pulls imagePullPolicy IfNotPresent."
