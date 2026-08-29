# Tailscale — secure mesh VPN for the cluster.
#
# Enables the tailscaled service + CLI. After deployment, connect each node
# to your tailnet once with `sudo tailscale up` (interactive auth URL).
#
# Reference: https://nixos.wiki/wiki/Tailscale

{ config, pkgs, lib, ... }:

{
  # Enable the Tailscale daemon.
  services.tailscale.enable = true;

  # Make the `tailscale` CLI available to users.
  environment.systemPackages = with pkgs; [ tailscale ];

  # The NixOS tailscale module opens its WireGuard port (UDP 41641) in the
  # firewall automatically when the firewall is enabled, so no manual rule
  # is needed here.
}
