# GL.iNet router (192.168.8.1). It joins the tailnet by hand in the GL.iNet UI (README.md,
# "Router"), logged in as the owner. Once var.router_hostname is set, Terraform tags it
# tag:router (which also turns off its key expiry) and approves its LAN route. The policy's
# autoApprovers would approve the route for tag:router as well, but only when the route is
# advertised after the tag is set; approving it here does not depend on that order.
# It never enables an exit node on the router: that is a switch in the GL.iNet UI.

data "tailscale_device" "router" {
  count    = var.router_hostname == "" ? 0 : 1
  hostname = var.router_hostname
  wait_for = "30s"
}

resource "tailscale_device_tags" "router" {
  count     = var.router_hostname == "" ? 0 : 1
  device_id = data.tailscale_device.router[0].node_id
  tags      = ["tag:router"]

  depends_on = [tailscale_acl.this]
}

resource "tailscale_device_subnet_routes" "router" {
  count     = var.router_hostname == "" ? 0 : 1
  device_id = data.tailscale_device.router[0].node_id
  routes    = [var.lan_cidr]

  depends_on = [tailscale_device_tags.router]
}
