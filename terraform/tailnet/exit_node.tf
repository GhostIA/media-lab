# Vultr VM that is a Tailscale exit node (tag:exit). NOT for torrents: see README.md.
# Public inbound traffic: WireGuard (UDP 41641) only. No public SSH; use `tailscale ssh`.

locals {
  exit_hostname = var.exit_node_hostname != "" ? var.exit_node_hostname : "vultr-exit-${var.vultr_region}"
}

resource "vultr_firewall_group" "exit" {
  description = "${local.exit_hostname}: tailscale only"
}

# Tailscale works without any inbound rule (NAT traversal / DERP); opening its WireGuard port
# lets peers connect directly instead of through a relay.
resource "vultr_firewall_rule" "tailscale_v4" {
  firewall_group_id = vultr_firewall_group.exit.id
  protocol          = "udp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = "41641"
  notes             = "tailscale wireguard"
}

resource "vultr_firewall_rule" "tailscale_v6" {
  firewall_group_id = vultr_firewall_group.exit.id
  protocol          = "udp"
  ip_type           = "v6"
  subnet            = "::"
  subnet_size       = 0
  port              = "41641"
  notes             = "tailscale wireguard"
}

resource "vultr_instance" "exit" {
  region            = var.vultr_region
  plan              = var.vultr_plan
  os_id             = var.vultr_os_id
  hostname          = local.exit_hostname
  label             = local.exit_hostname
  tags              = ["media-lab", "tailscale-exit"]
  enable_ipv6       = true
  backups           = "disabled" # nothing on it worth keeping: rebuild with -replace instead
  ddos_protection   = false
  activation_email  = false
  firewall_group_id = vultr_firewall_group.exit.id

  # the provider base64-encodes this for the API
  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    hostname = local.exit_hostname
    authkey  = tailscale_tailnet_key.exit.key
    tag      = local.exit_tag
    suite    = var.tailscale_apt_suite
  })

  lifecycle {
    # user_data only matters at first boot, and the single-use key in it is spent by then.
    # To rebuild the node: terraform apply -replace=tailscale_tailnet_key.exit -replace=vultr_instance.exit
    ignore_changes = [user_data]
  }
}
