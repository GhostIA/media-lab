# Adopt the live resources (created by the former pve-tools/vm-media-stack.sh) into state.
# Import blocks are idempotent: once the address is in state, they are no-ops.
import {
  to = proxmox_download_file.debian13
  id = "${var.node_name}/${var.image_datastore_id}:import/${var.image_file_name}"
}

import {
  to = proxmox_virtual_environment_vm.media_stack
  id = "${var.node_name}/${var.vm_id}"
}
