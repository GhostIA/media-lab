# The tailnet policy file = the tailnet's own rules (policy.base.json.tftpl, kept as they are)
# + the lab additions below. Nothing from the base is dropped or reordered: lists get the lab
# entries appended, maps get the lab keys added (a lab tag that the base already lists keeps the
# base's owners too). Check that with ./policy-diff.sh before every apply (README.md).

locals {
  lab_tags  = ["tag:pve", "tag:media", "tag:router"]
  exit_tag  = "tag:exit"
  base_text = templatefile("${path.module}/policy.base.json.tftpl", { id = var.policy_identities })
  # full-line // comments are allowed in the template; drop them so jsondecode can read it
  base = jsondecode(replace(local.base_text, "/(?m)^[ \\t]*//.*$/", ""))

  base_tag_owners = lookup(local.base, "tagOwners", {})
  base_auto       = lookup(local.base, "autoApprovers", {})
  base_routes     = lookup(local.base_auto, "routes", {})

  lab_tag_owners = merge(
    { (var.terraform_tag) = distinct(concat(lookup(local.base_tag_owners, var.terraform_tag, []), ["autogroup:admin"])) },
    {
      for t in concat(local.lab_tags, [local.exit_tag]) :
      t => distinct(concat(lookup(local.base_tag_owners, t, []), ["autogroup:admin", var.terraform_tag]))
    },
  )

  lab_grants = [
    # the owner/admins reach everything: lab devices, the LAN behind the router, exit nodes
    { src = [var.admin_src], dst = ["*"], ip = ["*"] },
    # lab devices reach each other (not the exit node, which only forwards traffic)
    { src = local.lab_tags, dst = local.lab_tags, ip = ["*"] },
    # allowed to USE an exit node (Vultr or Mullvad); each device still opts in itself
    { src = concat([var.admin_src], local.lab_tags), dst = ["autogroup:internet"], ip = ["*"] },
  ]

  lab_ssh = [
    # Tailscale SSH into the exit node (it has no public SSH); re-authenticate every 12 h
    {
      action      = "check"
      checkPeriod = "12h"
      src         = [var.ssh_src]
      dst         = [local.exit_tag]
      users       = ["root", "autogroup:nonroot"]
    },
  ]

  lab_node_attrs = [
    for a in [{ target = var.mullvad_targets, attr = ["mullvad"] }] : a if length(var.mullvad_targets) > 0
  ]

  # A public cloud VM must never reach into the lab, whatever the base rules say.
  lab_tests = [
    for t in [
      { src = local.exit_tag, deny = ["tag:pve:22", "tag:pve:8006", "tag:media:22", "tag:router:80", "${cidrhost(var.lan_cidr, 200)}:8989"] },
      { src = "tag:media", accept = ["tag:pve:8006", "tag:media:2049"] },
    ] : t if var.policy_tests
  ]

  policy = merge(local.base, {
    tagOwners = merge(local.base_tag_owners, local.lab_tag_owners)
    grants    = concat(lookup(local.base, "grants", []), local.lab_grants)
    autoApprovers = merge(local.base_auto, {
      exitNode = distinct(concat(lookup(local.base_auto, "exitNode", []), [local.exit_tag]))
      routes = merge(local.base_routes, {
        (var.lan_cidr) = distinct(concat(lookup(local.base_routes, var.lan_cidr, []), ["tag:router"]))
      })
    })
    ssh       = concat(lookup(local.base, "ssh", []), local.lab_ssh)
    nodeAttrs = concat(lookup(local.base, "nodeAttrs", []), local.lab_node_attrs)
    tests     = concat(lookup(local.base, "tests", []), local.lab_tests)
  })
}

resource "tailscale_acl" "this" {
  acl = jsonencode(local.policy)

  # Adopt the existing policy with the import block in import.tf instead (the plan then shows
  # exactly what changes); never blind-overwrite it.
  overwrite_existing_content = false
  # Destroying this resource only forgets it; the tailnet keeps its last policy.
  reset_acl_on_destroy = false

  lifecycle {
    precondition {
      condition     = !contains(keys(local.base), "__replace_with_current_policy")
      error_message = "policy.base.json.tftpl is still the placeholder. Put the tailnet's current policy in it first (README.md, Base policy)."
    }
  }
}

# The policy as it is in the tailnet right now: only used by policy-diff.sh (before vs after).
data "tailscale_acl" "current" {}
