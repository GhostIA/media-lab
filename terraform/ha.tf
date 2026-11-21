# Proxmox HA for VM 200 (PVE 9: HA rules replace the old HA groups).
#
# On a node failure (power loss, or a NIC hang that drops the node out of the corosync quorum) the
# node's watchdog fences it (self-reboot after ~60 s without quorum), then the HA manager starts
# VM 200 on another online node from the same Ceph disks. Expect ~2-4 minutes of downtime and an
# unclean guest shutdown (like a power cut). No data is copied: the disks never leave Ceph.
#
# Memory is the constraint: VM 200 needs ~5.2 GiB on its host (5 GiB dedicated + QEMU overhead)
# and the other nodes have ~4.4-5.3 GiB available next to their Ceph OSD. Check `free -m` on the
# target nodes before relying on this (see README.md, "High availability").

resource "proxmox_haresource" "media_stack" {
  resource_id  = "vm:${var.vm_id}"
  state        = "started"
  comment      = "media stack (Terraform)"
  max_restart  = var.ha_max_restart
  max_relocate = var.ha_max_relocate
  # stay on the node it failed over to: no automatic live migration back when the old node
  # returns (a flapping node, e.g. a NIC that keeps hanging, would otherwise bounce the VM)
  failback = false
  # PVE 9.2 automatic rebalancing: never move a 5 GiB VM between nodes on its own
  auto_rebalance = false

  depends_on = [proxmox_virtual_environment_vm.media_stack]
}

# Non-strict node affinity: prefer the home node, then the listed failover nodes; any other online
# node is still used as a last resort.
resource "proxmox_harule" "media_stack" {
  rule      = "media-stack"
  type      = "node-affinity"
  comment   = "VM 200: home node first, then nodes with free RAM and TSO off"
  resources = [proxmox_haresource.media_stack.resource_id]
  strict    = false
  nodes     = var.ha_node_priorities
}
