# Tailscale — secure mesh VPN for the cluster.
#
# Enables the tailscaled service + CLI. After deployment, connect each node
# to your tailnet once with `sudo tailscale up` (interactive auth URL).
#
# Exit node / subnet routing: useRoutingFeatures = "server"/"both" sets
# net.ipv4.ip_forward=1, net.ipv6.conf.all.forwarding=1 and loosens the
# firewall reverse-path filter so the node can act as an exit node.
# Reference: https://nixos.wiki/wiki/Tailscale

{ config, pkgs, lib, ... }:

{
  services.tailscale = {
    enable = true;
    # "server" = advertise routes/exit node; "client" = use other exit nodes.
    # "both" lets each node both offer and consume exit nodes.
    useRoutingFeatures = "both";
    # Advertise the LAN subnet into the tailnet so remote devices can reach
    # MetalLB services (Pi-hole .241, Traefik .240, etc.) directly.
    # NOTE: node0 is the designated subnet router; must be approved once in
    # the Tailscale admin console (Machines → node0 → Edit route settings).
    extraUpFlags = [ "--advertise-routes=192.168.3.0/24" ];
  };

  # Make the `tailscale` CLI available to users.
  environment.systemPackages = with pkgs; [ tailscale ];

  # UDP GRO forward tuning (fixes: "UDP GRO forwarding is suboptimally
  # configured on <iface>"). Applied on boot to the active wireless/wired
  # interface — enables rx-udp-gro-forwarding for higher UDP throughput.
  systemd.services.tailscale-udpgro = {
    description = "Enable UDP GRO forwarding for Tailscale";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for iface in $(ls /sys/class/net | grep -v -E 'lo|tailscale0|docker|veth|br-'); do
        ethtool -K "$iface" rx-udp-gro-forwarding on 2>/dev/null || true
      done
    '';
  };
}
