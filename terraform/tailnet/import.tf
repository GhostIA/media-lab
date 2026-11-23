# The tailnet already has a (customized) policy file. Adopt it instead of overwriting it: the
# first plan then shows "1 to import" plus the in-place change from the current policy to
# base + lab additions. A no-op once the resource is in state.
# CLI equivalent: terraform import tailscale_acl.this acl
import {
  to = tailscale_acl.this
  id = "acl"
}
