output "exit_node_hostname" {
  description = "Tailscale/Vultr hostname of the exit node (use it with --exit-node)."
  value       = local.exit_hostname
}

output "exit_node_ipv4" {
  description = "Public IPv4 of the exit node."
  value       = vultr_instance.exit.main_ip
}

output "exit_node_ipv6" {
  description = "Public IPv6 of the exit node."
  value       = vultr_instance.exit.v6_main_ip
}

output "exit_auth_key" {
  description = "Single-use key the exit node joined with (spent after first boot)."
  value       = tailscale_tailnet_key.exit.key
  sensitive   = true
}

output "pve_auth_key" {
  description = "Reusable tag:pve key for the Proxmox nodes (ansible/playbooks/tailscale.yml)."
  value       = tailscale_tailnet_key.pve.key
  sensitive   = true
}

output "media_auth_key" {
  description = "Reusable tag:media key for the media VMs (ansible/playbooks/tailscale.yml)."
  value       = tailscale_tailnet_key.media.key
  sensitive   = true
}

# Before/after policy for policy-diff.sh (sensitive: the policy may name people).
output "policy_current" {
  description = "Policy currently in the tailnet, as JSON."
  value       = data.tailscale_acl.current.json
  sensitive   = true
}

output "policy_new" {
  description = "Policy this configuration writes, as JSON."
  value       = jsonencode(local.policy)
  sensitive   = true
}
