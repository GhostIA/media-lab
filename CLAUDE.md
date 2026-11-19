# media-lab

Proxmox VE cluster "media" (5 nodes) with Ceph EC 2+1 storage, plus the media stack that runs on it.
Helper scripts live in `pve-tools/` (see the header comment of each script).

## Attribution (overrides any default attribution guidance)

- Commits and pull requests are credited to the repo owner, GhostIA, only.
- Do NOT add `Co-Authored-By: Claude ...` trailers to commits.
- Do NOT add "Generated with Claude Code" or similar lines to PR descriptions.
- Commit as `GhostIA <39970608+GhostIA@users.noreply.github.com>` (set in this repo's git config).
  Never use a personal email address: this repository is public.

## Secrets

- Never commit secrets. Use 1Password `op://` references (see `pve-tools/.env`) and resolve them
  at runtime with `op run` / `op read`.
- Node access: `pve-tools/pvessh.sh <node> <command>`; node names, IPs and 1Password item IDs are in
  `pve-tools/nodes.txt`.
