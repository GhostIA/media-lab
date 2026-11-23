# FlareSolverr

Proxy that gets past Cloudflare / DDoS-Guard challenges for indexers that use them. It runs a
headless Chromium; **Prowlarr** sends requests for tagged indexers through it.
([FlareSolverr/FlareSolverr](https://github.com/FlareSolverr/FlareSolverr))

| | |
|---|---|
| Address | `http://flaresolverr:8191` (compose network only; no host port is published) |
| Image | `ghcr.io/flaresolverr/flaresolverr:v3.5.2` (official, pinned) |
| State | none (no volumes) |
| Memory | Chromium: a few hundred MB while solving |

## Connect it to Prowlarr (once, in the UI)

1. Prowlarr → **Settings → Indexers** → **+** → **FlareSolverr**.
2. Name `FlareSolverr`, Tags: type **`flaresolverr`** (creates the tag), Host
   **`http://flaresolverr:8191/`** (container name: FlareSolverr and Prowlarr both run on VM 201 and
   share its Docker network; no host port is published), Request Timeout `60`. Keep the two on the
   same VM, or this name stops resolving.
3. **Test**, then **Save**.

## Using it

Add the tag **`flaresolverr`** to each indexer that is behind Cloudflare (edit indexer → Tags). Only
tagged indexers go through FlareSolverr. Untagged ones connect directly, which is faster. If an
indexer's test fails with a Cloudflare/"challenge" error, tag it and test again.

## Deploy / upgrade

```sh
cd ansible
ansible-playbook playbooks/media-stack.yml -e '{"media_stack_services": ["flaresolverr"]}' --check --diff
ansible-playbook playbooks/media-stack.yml -e '{"media_stack_services": ["flaresolverr"]}'
```

Health from the VM: `docker exec flaresolverr curl -fsS http://localhost:8191/health`.
Upgrade: bump the tag (see the [releases](https://github.com/FlareSolverr/FlareSolverr/releases)), PR,
deploy. Cloudflare changes often, so a stale FlareSolverr is the usual cause of new challenge failures.
