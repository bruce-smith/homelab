# Active Directory join module — declarative SSSD + Kerberos + NTP
#
# homelab.ad.enable = true  →  prepares the node to join homelab.local:
#   - SSSD (System Security Services Daemon): PAM/NSS bridge for AD
#   - Kerberos client (krb5.conf → windowsnode.homelab.local)
#   - realmd/adcli/sssd tools for the one-time join
#   - chrony NTP (time sync is CRITICAL for Kerberos, <5min skew)
#   - PAM + nsswitch wired for AD users
#
# One-time join (NOT in this module — needs credentials interactively):
#   sudo realm join homelab.local -U 'HOMELAB\joinuser'
#   (or: sudo adcli join homelab.local -U joinuser)
# Then the machine keytab lives at /etc/krb5.keytab — encrypt it with sops
# (see Home Lab - Cluster Active Directory Join.md plan) so it survives rebuilds.
#
# Local users + SSH keys are UNAFFECTED — SSSD adds AD auth on top; local
# users (node0@node0, node1@node1, ...) keep working from non-domain machines.
#
# NOTE: realmd's "join" writes /etc/krb5.keytab which is stateful — after
# joining, re-imports of this module must NOT wipe it (realmd handles this).

{ config, lib, pkgs, ... }:

{
  options.homelab.ad = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable AD join prep (SSSD + Kerberos + NTP) for homelab.local.";
    };
  };

  config = lib.mkIf config.homelab.ad.enable {
    # ── Kerberos client ─────────────────────────────────────────────────
    # Point at the DC. DNS must resolve windowsnode.homelab.local (Pi-hole
    # conditional forwarder → .196, verified).
    environment.etc."krb5.conf".text = ''
      [libdefaults]
        default_realm = HOMELAB.LOCAL
        dns_lookup_realm = false
        dns_lookup_kdc = true
        ticket_lifetime = 24h
        renew_lifetime = 7d
        forwardable = true
        rdns = false

      [realms]
        HOMELAB.LOCAL = {
          kdc = windowsnode.homelab.local
          admin_server = windowsnode.homelab.local
        }

      [domain_realm]
        .homelab.local = HOMELAB.LOCAL
        homelab.local = HOMELAB.LOCAL
    '';

    # ── SSSD ────────────────────────────────────────────────────────────
    # AD provider. Short timeouts so local-key SSH stays snappy if the DC
    # is unreachable (fallback to local users instead of hanging).
    services.sssd = {
      enable = true;
      config = ''
        [sssd]
        domains = homelab.local
        services = nss, pam, ssh

        [nss]
        filter_groups = root
        filter_users = root

        [pam]

        [domain/homelab.local]
        id_provider = ad
        auth_provider = ad
        # CRITICAL (2026-09-05): access_provider = ad enables GPO evaluation,
        # which fails with no GPOs configured ("GPO-based access control
        # failed" → pam_sss account phase "Access denied: System error").
        # Use 'simple' + allow all for the homelab — any valid AD user logs in.
        access_provider = simple
        simple_allow_all = true
        chpass_provider = ad
        ldap_schema = ad
        ad_domain = homelab.local
        krb5_server = windowsnode.homelab.local
        krb5_realm = HOMELAB.LOCAL
        ldap_uri = ldap://windowsnode.homelab.local
        ldap_search_base = DC=homelab,DC=local
        # Short timeouts so SSH stays fast if AD is down
        ldap_search_timeout = 3
        krb5_auth_timeout = 5
        krb5_validate = true
        offline_credentials_expiration = 2
        override_homedir = /home/%u
        default_shell = /run/current-system/sw/bin/bash
        use_fully_qualified_names = False
        fallback_homedir = /home/%u
      '';
    };

    # ── PAM / nsswitch ──────────────────────────────────────────────────
    # sssd module adds nsswitch entries; pam_mkhomedir creates homes.
    # CRITICAL FIX (2026-09-05): the NixOS sssd default auth stack is
    #   auth sufficient pam_sss.so use_first_pass
    #   auth required   pam_deny.so
    # With use_first_pass and NO earlier module capturing the password,
    # pam_sss gets an empty password → every AD SSH login fails with
    # "Preauthentication failed". Override the sshd service to capture the
    # password (pam_unix) then let pam_sss try it, with a deny fallback.
    security.pam.services.sshd = {
      sshAgentAuth = true;
      # Let AD users auth via PAM (kbd-interactive) while local keys still work
      rules.auth = {
        unix = {
          enable = lib.mkForce true;
          order = 1000;
          args = [ "nullok" ];
        };
        sss = {
          enable = true;
          order = 2000;
          args = [ "use_first_pass" ];
        };
      };
      rules.account = {
        sss = {
          enable = true;
          order = 1000;
        };
        unix = {
          enable = true;
          order = 2000;
        };
      };
      rules.session = {
        mkhomedir = {
          enable = lib.mkForce true;
          order = 1500;
          args = [ "skel=/etc/skel" "umask=0022" ];
        };
      };
    };
    # nsswitch is handled by services.sssd automatically (files → sss)

    # ── Join tools (one-time realm join) ────────────────────────────────
    environment.systemPackages = with pkgs; [
      realmd          # realm join
      adcli           # adcli join (alternative)
      sssd            # the daemon itself
      krb5            # kinit/klist
      cifs-utils      # optional: mount SMB shares
    ];

    # ── NTP (chrony) — CRITICAL for Kerberos ────────────────────────────
    # Sync from the DC (which syncs pool.ntp.org) or direct pool.
    services.chrony = {
      enable = true;
      # Prefer the DC as time source (it's stratum 3 via pool.ntp.org),
      # fall back to pool.ntp.org directly.
      servers = [
        "windowsnode.homelab.local iburst"
        "pool.ntp.org iburst"
      ];
    };

    # ── Firewall ────────────────────────────────────────────────────────
    # AD uses TCP/UDP 88 (kerberos), 389 (LDAP), 445 (SMB) — outbound only,
    # no inbound needed for a client. chrony uses UDP 123 outbound.
    # (NixOS default firewall allows outbound; nothing to open for a client.)

    # ── Ensure /etc/krb5.keytab survives rebuilds ───────────────────────
    # (realm join creates it; sops-nix integration is a later step per plan)
    systemd.tmpfiles.rules = [
      # nothing needed here yet — keytab handled by realm/sops
    ];
  };
}
