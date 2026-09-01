# k3s cluster module — ENABLED
#
# homelab.k3s.enable = true on all nodes (wired gigabit, 2026-09-01).
#
#   - node0 (dv6)          -> role = "server"  (control plane)
#   - node1 (Danny's HP15) -> role = "agent"   (worker)
#   - node2 (Grandpa's)    -> role = "agent"   (worker)
#
# TODO(secrets): move the shared token to sops-nix before publishing this repo
# publicly. See dreamsofautonomy/homelab for the sops-nix pattern.

{ config, lib, pkgs, ... }:

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

      # TODO(secrets): generate once with `openssl rand -hex 16` and move to
      # sops-nix (the video stores it via sops; don't hardcode long-term).
      token = "ecf950249dd7bb7a953b7e1373897937";

      # Agents join the server by name (resolves via router DHCP / hosts).
      # serverAddr is only set on agents — it's a plain string option.
      serverAddr = lib.mkIf (!isServer) "https://node0:6443";

      # Save RAM on the weaker laptops (video approach):
      #   - disable built-in traefik ingress  (we'll use nginx-ingress-controller)
      #   - disable built-in servicelb       (we'll use MetalLB)
      # NOTE: --disable is a SERVER-only flag in k3s; agents reject it.
      extraFlags = lib.mkIf isServer (toString [
        "--disable" "traefik"
        "--disable" "servicelb"
      ]);
    };

    # Open the ports k3s needs. This nixpkgs version has no openFirewall option
    # on services.k3s, so open them explicitly:
    #   6443 TCP = kube-apiserver (agents reach server on this)
    #   8472 UDP = flannel VXLAN   (node-to-node pod traffic)
    #   10250 TCP = kubelet metrics/health
    networking.firewall.allowedTCPPorts = [ 6443 10250 ];
    networking.firewall.allowedUDPPorts = [ 8472 ];

    # ── Longhorn prereq (enable alongside k3s) ───────────────────────────
    # Longhorn needs open-iscsi. NixOS path differs from the video's distro:
    #   iscsid service + the iscsiadm binary from the openiscsi package.
    services.openiscsi = {
      enable = true;
      name = "iqn.2026-08.homelab:${config.networking.hostName}";
    };
    environment.systemPackages = with pkgs; [ openiscsi ];

    # ── node role-specific tweaks ────────────────────────────────────────
    # Server keeps its local storage for etcd; workers can be tainted later.
    # RAM notes (before 16GB upgrade lands):
    #   node1 = 4GB locked  -> run 1 Longhorn replica / light workloads only
    #   node2 = 6GB (4.7GB after iGPU) -> worker
    # Consider after cluster up: k3s --node-taint, Longhorn replica counts.
  };
}
