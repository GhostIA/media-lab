# Auth comes from the environment (see .env.op and README.md):
#   tailscale: TAILSCALE_OAUTH_CLIENT_ID / TAILSCALE_OAUTH_CLIENT_SECRET (tailnet "-" = the client's own)
#   vultr:     VULTR_API_KEY
provider "tailscale" {}

provider "vultr" {
  rate_limit  = 700
  retry_limit = 3
}
