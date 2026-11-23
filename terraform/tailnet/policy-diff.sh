#!/bin/sh
# Show how the tailnet policy would change: current policy (from the API) vs what this
# configuration writes (base + lab additions), both as sorted JSON. Read-only: it only plans.
# A correct merge shows ONLY added lines ("+"); any "-" line means a rule of the tailnet would be
# removed or changed, so do not apply until the base template is fixed.
#
# usage (from terraform/tailnet/): ./policy-diff.sh
# Needs: op, terraform, jq. The plan file and JSON copies stay in a private temp dir and are
# deleted on exit (they contain the policy, which may name people).
set -eu
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

op run --env-file .env.op -- terraform plan -input=false -out="$tmp/plan" >/dev/null
terraform show -json "$tmp/plan" > "$tmp/plan.json"
# one line per leaf value, "path = value": appended list entries and new keys show up as pure
# additions (no trailing-comma noise from pretty-printed JSON)
# shellcheck disable=SC2016 # $o and $p are jq variables, not shell ones
flat='.planned_values.outputs[$o].value | fromjson
  | paths(scalars) as $p | "\($p | map(tostring) | join(".")) = \(getpath($p) | tojson)"'
jq -r --arg o policy_current "$flat" "$tmp/plan.json" | sort > "$tmp/current.json"
jq -r --arg o policy_new "$flat" "$tmp/plan.json" | sort > "$tmp/new.json"

if diff -u "$tmp/current.json" "$tmp/new.json" > "$tmp/diff"; then
  echo "No policy change."
  exit 0
fi
cat "$tmp/diff"
removed=$(tail -n +3 "$tmp/diff" | grep -c '^-' || true)
echo
if [ "$removed" -gt 0 ]; then
  echo "WARNING: $removed line(s) removed or changed from the current policy. Do not apply."
  exit 1
fi
echo "OK: additions only."
