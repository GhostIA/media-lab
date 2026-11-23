terraform {
  required_version = ">= 1.17"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "= 0.29.3"
    }
    vultr = {
      source  = "vultr/vultr"
      version = "= 2.33.2"
    }
  }
}
