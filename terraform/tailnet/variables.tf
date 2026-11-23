# --- tailnet policy (policy.tf) ---

variable "policy_identities" {
  description = <<-EOT
    Logins/emails that the base policy (policy.base.json.tftpl) refers to as $${id.<name>}, e.g.
    {"owner": "someone@example.com"}. The repo is public: set this only from 1Password
    (TF_VAR_policy_identities in .env.op) or a gitignored *.auto.tfvars, never in a committed file.
  EOT
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "terraform_tag" {
  description = "Tag of the Tailscale OAuth client. It owns every lab tag, so the client may mint keys for them and tag devices."
  type        = string
  default     = "tag:terraform"
}

variable "admin_src" {
  description = "Who may reach every device, subnet and exit node (grant src). autogroup:admin = the tailnet's owner and admins."
  type        = string
  default     = "autogroup:admin"
}

variable "ssh_src" {
  description = "Who may use Tailscale SSH into the exit node (ssh src). In a single-user tailnet autogroup:member is the owner."
  type        = string
  default     = "autogroup:member"
}

variable "lan_cidr" {
  description = "Home LAN advertised by the GL.iNet router and auto-approved for tag:router."
  type        = string
  default     = "192.168.8.0/24"
}

variable "mullvad_targets" {
  description = <<-EOT
    Devices allowed to use Mullvad exit nodes (nodeAttrs "mullvad"): tags (e.g. "tag:media") or
    groups. No logins/emails here (public repo); grant a person's own devices in the base policy
    with $${id.<name>} instead. Empty = no nodeAttrs entry. Needs the Mullvad add-on (bought in the
    admin console); each device that uses it takes one of the add-on's device slots (5 per license).
  EOT
  type        = list(string)
  default     = []
}

variable "policy_tests" {
  description = "Add policy tests that the exit node cannot reach the lab (apply fails if a base rule lets it)."
  type        = bool
  default     = true
}

# --- auth keys (keys.tf) ---

variable "exit_key_expiry_seconds" {
  description = "Lifetime of the exit node's single-use key. It only has to survive until cloud-init runs."
  type        = number
  default     = 3600
}

variable "lab_key_expiry_seconds" {
  description = "Lifetime of the reusable tag:pve / tag:media keys. Expired keys are re-minted by the next apply; joined devices are not affected."
  type        = number
  default     = 604800 # 7 days
}

# --- Vultr exit node (exit_node.tf) ---

variable "vultr_region" {
  description = "Vultr region of the exit node (outside the US). ams = Amsterdam."
  type        = string
  default     = "ams"
}

variable "vultr_plan" {
  description = "Vultr plan: vc2-1c-1gb = 1 vCPU, 1 GiB, 25 GB SSD, 1 TB/month transfer, USD 5/month (checked 2026-11-22)."
  type        = string
  default     = "vc2-1c-1gb"
}

variable "vultr_os_id" {
  description = "Vultr OS id: 2625 = Debian 13 x64 (trixie) (`GET https://api.vultr.com/v2/os`, 2026-11-22)."
  type        = number
  default     = 2625
}

variable "exit_node_hostname" {
  description = "Hostname of the exit node (Vultr and Tailscale). Empty = vultr-exit-<region>."
  type        = string
  default     = ""
}

variable "tailscale_apt_suite" {
  description = "Debian suite of the Tailscale apt repo on the exit node (must match vultr_os_id)."
  type        = string
  default     = "trixie"
}

# --- GL.iNet router (router.tf) ---

variable "router_hostname" {
  description = <<-EOT
    Tailscale hostname of the GL.iNet router once it has joined (admin console, Machines).
    Empty = Terraform does not touch the router. Set it to tag the router tag:router and
    approve its LAN route.
  EOT
  type        = string
  default     = ""
}
