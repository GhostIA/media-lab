#!/bin/sh
# SSH_ASKPASS helper: prints the password of the 1Password item in $OP_REF
# (format "<vault-id>/<item-id>") so ssh can read it. Never run it by hand.
exec op read "op://$OP_REF/password"
