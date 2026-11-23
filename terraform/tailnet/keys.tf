# Pre-authorized, tagged auth keys. They are stored in terraform.tfstate (and so in its 1Password
# backup); read them with `terraform output -raw <name>`, which needs no credentials.
# The OAuth client may only mint keys with tags owned by var.terraform_tag (policy.tf).

# Exit node: single-use and short-lived, because it is also copied into the instance's
# user_data (Vultr metadata) and cloud-init files. Once used or expired it is worthless and is
# not re-minted (recreate_if_invalid = never), so later plans stay quiet.
resource "tailscale_tailnet_key" "exit" {
  description         = "vultr exit node"
  reusable            = false
  ephemeral           = false
  preauthorized       = true
  expiry              = var.exit_key_expiry_seconds
  tags                = [local.exit_tag]
  recreate_if_invalid = "never"

  # the tags must exist in the policy before a key can carry them
  depends_on = [tailscale_acl.this]
}

# Proxmox nodes (ansible/playbooks/tailscale.yml). Reusable for the 5 nodes, 7 days by default;
# an expired key is replaced on the next apply (recreate_if_invalid = always). Devices that
# already joined are not affected by the key expiring (tagged devices have no key expiry).
resource "tailscale_tailnet_key" "pve" {
  description         = "proxmox nodes"
  reusable            = true
  ephemeral           = false
  preauthorized       = true
  expiry              = var.lab_key_expiry_seconds
  tags                = ["tag:pve"]
  recreate_if_invalid = "always"
  depends_on          = [tailscale_acl.this]
}

# Media VMs 200/201 (ansible/playbooks/tailscale.yml).
resource "tailscale_tailnet_key" "media" {
  description         = "media vms"
  reusable            = true
  ephemeral           = false
  preauthorized       = true
  expiry              = var.lab_key_expiry_seconds
  tags                = ["tag:media"]
  recreate_if_invalid = "always"
  depends_on          = [tailscale_acl.this]
}
