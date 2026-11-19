# Terraform: VM 200 `media-stack`

Defines the media stack VM (VMID 200 on `intel-a163f8`, disks on Ceph `media-ec`) and the Debian 13
cloud image it was created from, with the [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/0.123.1)
provider (pinned to `0.123.1`, Terraform `>= 1.17`). Replaces the `image`, `create` and `start`
phases of the old `pve-tools/vm-media-stack.sh`; the guest setup (docker, `/data`) is Ansible
(`ansible/playbooks/media-host.yml`).

| File | Content |
|---|---|
| `versions.tf` | Terraform and provider version pins |
| `main.tf` | `proxmox_download_file.debian13`, `proxmox_virtual_environment_vm.media_stack` |
| `variables.tf` | every value of the live VM (defaults = current config) |
| `outputs.tf` | VMID, node, IP, MAC, image volume ID |
| `import.tf` | `import {}` blocks that adopt the existing image and VM |
| `.env.op` | provider auth as `op://` references only |
| `.terraform.lock.hcl` | provider checksums (darwin/linux, arm64/amd64) |

## 1. API token (once)

Terraform logs in as `terraform@pve!media`. Create the user, the least-privilege role `TerraformVM`,
its ACLs and the token, and store the secret in 1Password item `pve-terraform` (vault Lab):

```sh
cd ansible && ansible-playbook playbooks/pve-terraform-token.yml
```

The playbook only creates the token when the 1Password item does not exist, and stores it right
away (`token_id`, `token_secret`, `api_token` = `terraform@pve!media=<secret>`, `endpoint`).
Reruns report `changed=0`. Permissions (privsep=0 token, so the token has exactly these):

| Role | Privileges | ACL paths (propagate) |
|---|---|---|
| `TerraformVM` | `VM.Allocate`, `VM.Audit`, `VM.Config.{CDROM,CPU,Cloudinit,Disk,HWType,Memory,Network,Options}`, `VM.GuestAgent.Audit`, `VM.Migrate`, `VM.PowerMgmt`, `Datastore.{AllocateSpace,AllocateTemplate,Audit}`, `SDN.Use`, `Pool.Audit` | `/vms/200`, `/storage/media-ec`, `/storage/local`, `/sdn/zones/localnetwork` |
| `TerraformNode` | `Sys.Audit`, `Sys.AccessNetwork` (download-url accepts it on the node instead of `Sys.Modify` on `/`) | `/nodes/intel-a163f8` |

Any other ACL of `terraform@pve` is removed by the playbook.

## 2. Run

Always through `op run`, which resolves `.env.op` into `PROXMOX_VE_ENDPOINT`,
`PROXMOX_VE_API_TOKEN` and `PROXMOX_VE_INSECURE=true` (PVE has a self-signed certificate):

```sh
cd terraform
terraform init
op run --env-file .env.op -- terraform plan
op run --env-file .env.op -- terraform apply   # only after reading the plan
```

If `op run` reports an item as deleted right after it was recreated, add `--cache=false`
(`op --cache=false run ...`). No SSH is needed: all resources use the PVE API only.

Expected result on the live cluster: **`No changes. Your infrastructure matches the configuration.`**

Safety rails:

- `prevent_destroy = true` on the VM: any plan that would destroy or replace VM 200 errors out.
- Never apply a plan that shows `-/+` or `must be replaced` for the VM or its disks. Changes to
  CPU, memory or hardware may need a reboot, which the provider does by itself
  (`reboot_after_update` defaults to `true`); schedule those.
- Disk sizes can only grow. Shrinking `os_disk_gb`/`data_disk_gb` is refused by PVE.

## 3. Import procedure (how the live VM was adopted)

The VM and image existed before Terraform. `import.tf` adopts them:

- image: `intel-a163f8/local:import/debian-13-genericcloud-amd64.qcow2`
- VM: `intel-a163f8/200`

Steps that were run (and that you repeat if the state is ever lost, see §5):

```sh
op run --env-file .env.op -- terraform plan -out=import.tfplan
#   Plan: 2 to import, 0 to add, 1 to change, 0 to destroy.
#   VM: import only (no-op). Image: import + in-place update of provider-only attributes
#   (overwrite, overwrite_unmanaged, upload_timeout, verify: null after import). The provider's
#   Update for this resource only re-reads the file listing; it makes no write call to PVE.
op run --env-file .env.op -- terraform apply import.tfplan
op run --env-file .env.op -- terraform plan     # -> No changes
```

Check `qm config 200` on intel-a163f8 before and after (`diff` must be empty); it was.

## 4. `ignore_changes` and why

| Resource | Attribute | Reason |
|---|---|---|
| `proxmox_download_file.debian13` | `url` | PVE does not record where a file came from, so after an import `url` is null in state, and `url` is `RequiresReplace`: without the ignore, every plan would delete and re-download the image. It only matters when the file is created. |
| `proxmox_virtual_environment_vm.media_stack` | `disk[0].import_from` | Creation-time instruction (copy the cloud image into a new scsi0). PVE does not keep it in the VM config, so it can never be read back. |

Also deliberate: the image has `overwrite = false`. The URL is Debian's `.../latest/`, which changes
with every point release; with the default `true` the provider would replace the image on the
node whenever upstream changes. The VM does not need the image after creation.

The cloud-init SSH key is read from `~/.ssh/id_ed25519.pub` (`ssh_public_key_file`), the same key
Ansible uses everywhere in this repo. Running Terraform from a machine with a different key shows
an in-place change of `initialization.user_account.keys`: do not apply that; set
`ssh_public_key_file` to the original key instead.

Everything else (CPU, memory, disks, cloud-init user/keys/IP/DNS, MAC, serial console, boot order)
is read back from PVE and compared on every plan.

## 5. State

State is local (`terraform/terraform.tfstate`, gitignored). It holds no secrets (the API token is
only in the environment), but losing it means re-importing. After every apply:

```sh
cp terraform.tfstate ~/Backups/media-lab/terraform.tfstate.$(date +%Y%m%d-%H%M%S)
# or keep it in 1Password as a document:
op document create terraform.tfstate --vault Lab --title media-lab-tfstate   # first time
op document edit media-lab-tfstate terraform.tfstate --vault Lab             # afterwards
```

If the state is lost: `terraform init`, then repeat §3 (the `import {}` blocks are still in
`import.tf` and are no-ops once the resources are in state).
