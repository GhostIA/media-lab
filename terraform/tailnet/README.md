# Terraform: tailnet and Vultr exit node

Puts the lab on Tailscale. A separate Terraform root from `terraform/` (the Proxmox VMs), with its
own local state, its own state backup and its own credentials. It does not touch the Proxmox
root or its state.

What it manages:

- **The tailnet policy file** (`tailscale_acl`). The tailnet's **own rules are kept**: they live
  in `policy.base.json.tftpl`, and `policy.tf` merges the lab additions into them (tags, grants,
  `autoApprovers`, a Tailscale SSH rule, `nodeAttrs` for Mullvad, policy tests). Nothing from the
  base is removed.
- **Auth keys** (`tailscale_tailnet_key`): pre-authorized and tagged. One single-use 1-hour key
  for the exit node, and reusable 7-day keys `tag:pve` (Proxmox nodes) and `tag:media` (VMs
  200/201) for `ansible/playbooks/tailscale.yml`.
- **A Vultr exit node** `vultr-exit-ams` (`tag:exit`): Debian 13, 1 vCPU / 1 GiB in Amsterdam. Its
  firewall allows inbound UDP 41641 (WireGuard) only. It has no public SSH; use `tailscale ssh`.
- **The GL.iNet router** (optional, once it has joined by hand): tagged `tag:router`, with its
  LAN route `192.168.8.0/24` approved.

**Nothing uses an exit node by default.** Each device opts in itself (see "Using an exit node").

Providers: [`tailscale/tailscale` 0.29.3](https://registry.terraform.io/providers/tailscale/tailscale/0.29.3)
and [`vultr/vultr` 2.33.2](https://registry.terraform.io/providers/vultr/vultr/2.33.2), pinned
exactly (released 2026-10-28 and 2026-10-14). Terraform `>= 1.17`.

> **The Vultr node is not for torrents.** Vultr forwards DMCA notices and suspends accounts over
> them. qBittorrent stays off it. If torrents should ever leave through a VPN, the plan is a
> Mullvad exit node via a Tailscale sidecar in qBittorrent's compose project. That is a later PR.

| File | Content |
|---|---|
| `versions.tf`, `providers.tf` | version pins; providers authenticate from the environment |
| `policy.base.json.tftpl` | **the tailnet's own policy** (JSON, `${id.<name>}` instead of logins/emails) |
| `policy.tf` | merge of base + lab additions, `tailscale_acl.this`, `data.tailscale_acl.current` |
| `import.tf` | `import {}` that adopts the existing policy instead of overwriting it |
| `policy-diff.sh` | current policy vs new policy, flattened; must show additions only |
| `keys.tf` | the three auth keys |
| `exit_node.tf`, `cloud-init.yaml.tftpl` | Vultr firewall group/rules and instance; first-boot setup |
| `router.tf` | tag and route approval for the GL.iNet router (off while `router_hostname = ""`) |
| `variables.tf`, `outputs.tf` | settings (defaults = the plan below); IPs, hostname, keys (sensitive) |
| `.env.op` | provider credentials as `op://` references only |

## Costs

| What | Price |
|---|---|
| Vultr `vc2-1c-1gb` (1 vCPU, 1 GiB, 25 GB SSD, 1 TB/month transfer), `ams` | USD 5.00/month (about USD 0.007/hour; checked 2026-11-22 on `api.vultr.com/v2/plans`). IPv6 is free. Automatic backups are off (they would add 20%) |
| Transfer above 1 TB/month | billed per GB by Vultr; an exit node used for browsing stays far below it |
| Tailscale | Personal plan: free |
| Mullvad add-on (optional) | bought in the Tailscale admin console, about USD 5/month for 5 devices |

Destroying the instance stops the Vultr charge (see "Destroy").

## 1Password items

| Item (vault) | Fields | Used as |
|---|---|---|
| `Vultr` (`y2gzkuozzzojcdddk25gspbe3m`, item id `4kfc3hdgfzuaq6t2pebm6err54`) | `api key` | `VULTR_API_KEY` |
| `tailscale-terraform` (Lab, `xmjfgnsondcvlqa6bovelwdztm`), **create it in the bootstrap** | `client_id`, `client_secret`, `policy_identities` | `TAILSCALE_OAUTH_CLIENT_ID`, `TAILSCALE_OAUTH_CLIENT_SECRET`, `TF_VAR_policy_identities` |
| document `media-lab-tailnet-tfstate` (Lab) | this root's `terraform.tfstate` | backup, see "State" |

`.env.op` points at the Vultr field by its label (`.../api key`, quoted because of the space).
To use the field id instead, list ids and labels only (no values):

```sh
op item get 4kfc3hdgfzuaq6t2pebm6err54 --vault y2gzkuozzzojcdddk25gspbe3m --format json \
  | jq -r '.fields[] | "\(.id)\t\(.label)"'
```

`policy_identities` is a JSON object that maps the placeholders used in the base policy to
the real logins, e.g. `{"owner": "someone@example.com"}`, or `{}` when the policy names nobody. This
repo is public, so logins and emails exist only in that field (and in the state).

## Bootstrap (once, in this order)

The OAuth client has to be created with a tag, and the admin console only offers tags that
already exist in the policy. Terraform cannot create the policy without the client. So the tags
are put in by hand first, and Terraform takes the policy over afterwards.

1. **Save the current policy.** Admin console → **Access controls** → JSON editor: copy
   everything into `terraform/tailnet/policy.current.hujson` (gitignored), so you can
   always restore it.

2. **Add the tags by hand.** In the same editor, add these entries to `tagOwners` (create the
   block if it is missing) and save:

   ```jsonc
   "tagOwners": {
     "tag:terraform": ["autogroup:admin"],
     "tag:exit":      ["autogroup:admin", "tag:terraform"],
     "tag:pve":       ["autogroup:admin", "tag:terraform"],
     "tag:media":     ["autogroup:admin", "tag:terraform"],
     "tag:router":    ["autogroup:admin", "tag:terraform"],
   },
   ```

   `tag:terraform` is the OAuth client's own tag. Because it owns the four lab tags, the client
   may mint keys carrying them and put them on devices.

3. **Create the OAuth client.** Admin console → **Settings** → **Trust credentials** (formerly
   "OAuth clients") → generate a credential, owned by the tailnet, with these scopes (all
   **write**):

   | Scope | Tags | Needed for |
   |---|---|---|
   | `policy_file` | none | `tailscale_acl`. The console also requires `devices:core:read` and `devices:posture_attributes` with it |
   | `auth_keys` | `tag:terraform` | `tailscale_tailnet_key` (keys can carry `tag:terraform` or the tags it owns) |
   | `devices:core` | `tag:terraform` | `tailscale_device_tags` and `data.tailscale_device` (router) |
   | `devices:routes` | none | `tailscale_device_subnet_routes` (router LAN route) |

   Copy the client ID and secret (the console shows the secret only once).

4. **Create the 1Password item** `tailscale-terraform` in vault Lab. Use the 1Password app, so
   the secret never goes through the shell history. Add the fields `client_id` (text),
   `client_secret` (password) and `policy_identities` (text, `{}` for now).

5. **Fill in the base policy.** Replace the placeholder object in `policy.base.json.tftpl` with
   the policy from step 2 (including the new `tagOwners`). Then:
   - make it plain JSON: remove trailing commas and end-of-line comments. Full-line `//`
     comments are fine; they are stripped before parsing.
   - replace every login/email with a placeholder, e.g. `"${id.owner}"`, and put the values in
     the `policy_identities` field: `{"owner": "you@example.com", ...}`.
   - make sure the `__replace_with_current_policy` key is gone. While it is there, every plan
     fails on purpose.

   Comments in the console's HuJSON are lost on the first apply (the provider writes JSON). Keep
   the ones worth keeping as `//` lines in the template.

6. **Init and compare.** From `terraform/tailnet/`:

   ```sh
   terraform init
   ./policy-diff.sh       # current vs new policy, one line per value
   ```

   It must print **`OK: additions only.`** Every line should start with `+`: new tag owners,
   the lab grants, the exit-node/route auto-approvers, the SSH rule, the tests. A `-` line means
   one of the tailnet's rules would change. Fix the template and run it again; do not apply.

7. **Apply the policy first, then the rest.** Read each plan before applying it:

   ```sh
   op run --env-file .env.op -- terraform plan -target=tailscale_acl.this -out=acl.tfplan
   #   Plan: 1 to import, 0 to add, 1 to change, 0 to destroy.
   op run --env-file .env.op -- terraform apply acl.tfplan
   op run --env-file .env.op -- terraform plan -out=tailnet.tfplan
   #   Plan: 7 to add (3 keys, firewall group, 2 rules, instance), 0 to change, 0 to destroy.
   op run --env-file .env.op -- terraform apply tailnet.tfplan
   rm -f *.tfplan
   ```

   The policy tests run on every policy write: the apply fails if any rule (yours or the lab's)
   lets `tag:exit` reach the lab. If your base policy still has the default "everyone reaches
   everything" rule (`"src": ["*"], "dst": ["*:*"]` or a `*` grant), narrow it, because a public
   VM must not reach your LAN. Or set `policy_tests = false` knowingly.

8. **Back up the state** (see "State"), then check the exit node. After 2-4 minutes it shows up
   in the admin console as `vultr-exit-ams`, tagged `tag:exit`, with "Exit node" approved:

   ```sh
   tailscale status | grep vultr-exit
   tailscale ssh root@vultr-exit-ams 'cloud-init status; tailscale status --self'
   ```

9. **Lab hosts:** `cd ../../ansible && ansible-playbook playbooks/tailscale.yml --check --diff`,
   then without `--check` (it reads the `pve_auth_key` / `media_auth_key` outputs from this
   state). See `ansible/README.md`.

10. **Router:** see "Router (GL.iNet)", then set `router_hostname` and apply again.

## Everyday use

```sh
cd terraform/tailnet
op run --env-file .env.op -- terraform plan       # expected: No changes
./policy-diff.sh                                  # before any policy change
op run --env-file .env.op -- terraform apply      # only after reading the plan
```

After an apply, back up the state. The reusable lab keys expire after 7 days. A later plan
shows them as replaced (`recreate_if_invalid = always`). That is harmless: devices that have
joined keep working. The exit node's spent key is never re-minted.

Edit the policy only here (in the template or `policy.tf`), not in the admin console: the
next apply would revert console edits. If someone did edit in the console, `policy-diff.sh`
shows those edits as `-` lines. Copy them into the template first.

## Router (GL.iNet)

The router (`192.168.8.1`, gl-ui firmware with built-in Tailscale) is set up by hand. The
labels below are from GL.iNet firmware 4.x and may differ slightly between versions:

1. Admin panel <http://192.168.8.1> → **Applications** → **Tailscale**.
2. Turn on **Enable Tailscale** and apply. Open the **Device Bind Link**, sign in with the
   tailnet's owner account and connect the device.
3. Turn on **Allow Remote Access LAN**. This advertises `192.168.8.0/24`.
4. Leave **Allow Remote Access WAN** and **Custom Exit Node** **off**. The router then does not
   send the house's traffic through any exit node. Turning **Custom Exit Node** on later, and
   picking `vultr-exit-ams` or a Mullvad node, is your choice. It routes every LAN device
   through that exit node.
5. Apply. In the admin console note the router's machine name, then set it as the default of
   `router_hostname` in `variables.tf` (not secret) and apply:

   ```sh
   op run --env-file .env.op -- terraform plan     # 2 to add: tailscale_device_tags.router, tailscale_device_subnet_routes.router
   op run --env-file .env.op -- terraform apply
   ```

   This tags the router `tag:router` (which also turns off its key expiry) and approves the LAN
   route. The `autoApprovers` entry approves the route as well whenever the tagged router
   advertises it again.

Lab hosts do not accept the route (`--accept-routes=false`): they are on that LAN already.
Laptops and phones away from home reach `192.168.8.x` through it. A Mac on the home LAN with
"Use Tailscale subnets" on may also send LAN traffic through the router; that still works.
Turn the option off at home if it feels slow.

## Using an exit node (opt-in per device)

No device uses one until you choose. The policy allows the owner/admins and the lab tags to use
exit nodes (`autogroup:internet`).

- **Mac / phone:** Tailscale menu → **Exit node** → `vultr-exit-ams` (or a Mullvad location);
  turn on "Allow local network access".
- **Linux host:**

  ```sh
  tailscale set --exit-node=vultr-exit-ams --exit-node-allow-lan-access=true
  tailscale set --exit-node=                       # back to normal
  ```

> **Not on the Proxmox nodes.** Corosync, Ceph and the NFS mount between VM 200 and VM 201
> must stay on the LAN. An exit node changes the host's default route. If
> `--exit-node-allow-lan-access` is left off, the host loses its LAN. A broken path then fences
> the node (watchdog reboot) and can take Ceph below quorum. The Ansible role refuses to run on a
> lab host with an exit node unless that host has `tailscale_allow_exit_node: true` and LAN
> access on.

## Mullvad exit nodes

1. Admin console → **Settings** → **Mullvad VPN** (add-on): buy it. It covers 5 devices per
   license.
2. Give devices access through the policy's `nodeAttrs`: set `mullvad_targets` (tags or groups
   only, e.g. `["tag:media"]`; empty by default) and apply. For your own phone/laptop, add a
   `nodeAttrs` entry with `"target": ["${id.owner}"], "attr": ["mullvad"]` to the base template.
3. On the device, pick a Mullvad exit node (`tailscale exit-node list`, then
   `tailscale set --exit-node=<name> --exit-node-allow-lan-access=true`, or the client's menu).

Each device that uses Mullvad takes a license slot while it is connected.

## Exit node details

- First boot (`cloud-init.yaml.tftpl`): full `apt upgrade`, unattended-upgrades, IPv4/IPv6
  forwarding (`/etc/sysctl.d/99-tailscale-exit-node.conf`), Tailscale from
  `pkgs.tailscale.com/stable/debian trixie`, then
  `tailscale up --advertise-exit-node --advertise-tags=tag:exit --ssh --hostname=vultr-exit-ams`,
  Tailscale auto-updates, and OpenSSH disabled. The `exitNode` auto-approver approves it.
- **The auth key is in the state and in Vultr's instance metadata** (user_data, readable from the
  instance and the Vultr API). That is why it is single-use and expires after an hour. It is
  spent once the node joins, and the copy on disk is shredded. The instance's root password
  (Vultr-generated) is also in the state.
- Access: `tailscale ssh root@vultr-exit-ams` (the policy's `check` rule asks you to
  re-authenticate every 12 h). Break-glass: Vultr portal → instance → **View Console**, root
  password from the portal.
- Vultr's firewall group only lets UDP 41641 in (IPv4 and IPv6). Tailscale also works without
  it (via relays); with it, connections are direct.
- `user_data` is ignored after creation. To rebuild (new OS, new region):
  ```sh
  op run --env-file .env.op -- terraform apply -replace=tailscale_tailnet_key.exit -replace=vultr_instance.exit
  ```
  Remove the old machine in the admin console first, or the new one joins as
  `vultr-exit-ams-1`. Changing `vultr_region` or the hostname replaces the instance anyway; replace
  the key in the same apply.

## State

Local `terraform/tailnet/terraform.tfstate` (gitignored). Unlike the Proxmox root, **it holds
secrets**: the auth keys, the exit node's root password, and the policy with the real logins.
Its backup is the 1Password document **`media-lab-tailnet-tfstate`** in vault Lab.

First time, after the first apply (from `terraform/tailnet/`):

```sh
op document create terraform.tfstate --title media-lab-tailnet-tfstate --vault xmjfgnsondcvlqa6bovelwdztm
```

After **every** later apply:

```sh
op document edit media-lab-tailnet-tfstate terraform.tfstate --vault xmjfgnsondcvlqa6bovelwdztm
op document get media-lab-tailnet-tfstate --vault xmjfgnsondcvlqa6bovelwdztm --out-file /tmp/s && cmp terraform.tfstate /tmp/s && rm /tmp/s
```

Restore (new checkout or lost file), from the repo root:

```sh
op document get media-lab-tailnet-tfstate --vault xmjfgnsondcvlqa6bovelwdztm --out-file terraform/tailnet/terraform.tfstate
chmod 600 terraform/tailnet/terraform.tfstate
```

If the state is lost for good: the `import {}` block re-adopts the policy, the keys are minted
again, and the existing Vultr instance must be imported
(`terraform import vultr_instance.exit <instance id>`, plus its firewall group and rules) or
destroyed in the Vultr portal and recreated.

## Destroy

```sh
op run --env-file .env.op -- terraform destroy -target=vultr_instance.exit \
  -target=vultr_firewall_rule.tailscale_v4 -target=vultr_firewall_rule.tailscale_v6 \
  -target=vultr_firewall_group.exit -target=tailscale_tailnet_key.exit
```

This removes the exit node (and its cost). Then delete its machine in the admin console. A full
`terraform destroy` also revokes the lab keys (joined devices stay joined) and drops the router's
tag and route approval. It leaves the policy as it is (`reset_acl_on_destroy = false`): Terraform
only stops managing it.
Back up the state afterwards.
