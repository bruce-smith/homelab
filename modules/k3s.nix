# k3s cluster module — ENABLED
#
# homelab.k3s.enable = true on all nodes (wired gigabit, 2026-09-01).
#
#   - node0 (dv6)          -> role = "server"  (control plane)
#   - node1 (Danny's HP15) -> role = "agent"   (worker)
#   - node2 (Grandpa's)    -> role = "agent"   (worker)
#
# Secrets moved to sops-nix (2026-09-01): k3s token is decrypted from
# secrets/k3s-token.yaml at activation into /run/secrets/k3s-token, and
# referenced via tokenFile (never appears in the world-readable nix store).

{ config, lib, pkgs, secretsFile, ... }:

let
  isServer = config.networking.hostName == "node0";
in
{
  options.homelab.k3s = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable k3s on this node. Set true once wired to the switch.";
    };
  };

  config = lib.mkIf config.homelab.k3s.enable {
    # ── k3s ──────────────────────────────────────────────────────────────
    services.k3s = {
      enable = true;
      role = if isServer then "server" else "agent";

      # Read the shared token from sops-nix's decrypted file (see below).
      tokenFile = config.sops.secrets."k3s-token".path;

      # Agents join the server by name (resolves via router DHCP / hosts).
      # serverAddr is only set on agents — it's a plain string option.
      serverAddr = lib.mkIf (!isServer) "https://node0:6443";

      # Save RAM on the weaker laptops (video approach):
      #   - disable built-in traefik ingress  (we use MetalLB + Traefik via helmfile)
      #   - disable built-in servicelb       (we use MetalLB)
      # NOTE: --disable is a SERVER-only flag in k3s; agents reject it.
      extraFlags = lib.mkIf isServer (toString [
        "--disable" "traefik"
        "--disable" "servicelb"
      ]);
    };

    # ── sops-nix: decrypt secrets at activation ──────────────────────────
    sops = {
      # Resolved against the flake root (passed in via specialArgs) — using a
      # module-relative path here would break because modules live in the store.
      defaultSopsFile = secretsFile;
      age.keyFile = "/etc/sops/age/keys.txt";
      secrets."k3s-token" = { };
    };

    # Open the ports k3s needs. This nixpkgs version has no openFirewall option
    # on services.k3s, so open them explicitly:
    #   6443 TCP = kube-apiserver (agents reach server on this)
    #   8472 UDP = flannel VXLAN   (node-to-node pod traffic)
    #   10250 TCP = kubelet metrics/health
    #   9100 TCP = node-exporter (kube-prometheus-stack DaemonSet)
    networking.firewall.allowedTCPPorts = [ 6443 10250 9100 ];
    networking.firewall.allowedUDPPorts = [ 8472 ];

    # ── Longhorn prereq (enable alongside k3s) ───────────────────────────
    # Longhorn needs open-iscsi. NixOS path differs from the video's distro:
    #   iscsid service + the iscsiadm binary from the openiscsi package.
    services.openiscsi = {
      enable = true;
      name = "iqn.2026-08.homelab:${config.networking.hostName}";
    };
    environment.systemPackages = with pkgs; [ openiscsi nfs-utils ];

    # Longhorn's environment check runs `nsenter ... iscsiadm` and looks for
    # it at FHS paths (/usr/bin/iscsiadm, /usr/sbin/...). NixOS keeps binaries
    # in /run/current-system/sw/bin, so the check fails. Create FHS symlinks.
    systemd.tmpfiles.rules = [
      "L+ /usr/bin/iscsiadm - - - - /run/current-system/sw/bin/iscsiadm"
      "L+ /usr/sbin/iscsiadm - - - - /run/current-system/sw/bin/iscsiadm"
      "L+ /usr/bin/nsenter - - - - /run/current-system/sw/bin/nsenter"
    ];

    # ── node role-specific tweaks ────────────────────────────────────────
    # Server keeps its local storage for etcd; workers can be tainted later.
    # RAM notes (before 16GB upgrade lands):
    #   node1 = 4GB locked  -> run 1 Longhorn replica / light workloads only
    #   node2 = 6GB (4.7GB after iGPU) -> worker
    # Consider after cluster up: k3s --node-taint, Longhorn replica counts.
  };
}
