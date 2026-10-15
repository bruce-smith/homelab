# DNS resilience — break the Pi-hole single point of failure.
#
# Discovered after the 2026-10 power outage: the nodes resolved EVERYTHING
# through Tailscale MagicDNS (100.100.100.100), which forwarded to Pi-hole
# (192.168.3.241) as its ONLY configured resolver. When Pi-hole restarted on a
# node that lacked its image, the image pull needed DNS, and Pi-hole *was* the
# DNS -> permanent deadlock until a human intervened.
#
# Fix:
#   - Nodes do NOT need tailnet name resolution (they are reached by LAN IP /
#     router DHCP names; k3s joins by LAN name). Drop --accept-dns so tailscaled
#     stops rewriting /etc/resolv.conf. Tailscale stays for routing/subnet.
#   - System resolver: Pi-hole first (ad-blocking + homelab.local forwarding
#     to the AD DC), Cloudflare 1.1.1.1 second. glibc tries nameservers in
#     order, so if Pi-hole is unreachable the nodes still resolve -> containerd
#     can pull Pi-hole's image -> the cluster self-heals after a power loss.
#   - NetworkManager must stop rewriting resolv.conf (dns = "none") so the
#     networking.nameservers list below actually lands in /etc/resolv.conf.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  networking.networkmanager.dns = "none";
  networking.nameservers = [
    "192.168.3.241" # Pi-hole (primary: ad-block + AD conditional forwarder)
    "1.1.1.1" # Cloudflare (backup: survives Pi-hole being down)
  ];

  # Tailscale: keep the encrypted mesh + subnet-route advertisement, but stop
  # it from owning DNS on these nodes (that ownership was the single point
  # of failure).
  services.tailscale.extraUpFlags = [ "--accept-dns=false" ];
}