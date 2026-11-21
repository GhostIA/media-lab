output "vm_id" {
  description = "VMID of the media stack VM."
  value       = proxmox_virtual_environment_vm.media_stack.vm_id
}

output "vm_node" {
  description = "Node the VM runs on."
  value       = proxmox_virtual_environment_vm.media_stack.node_name
}

output "vm_ipv4" {
  description = "Static IPv4 address configured through cloud-init."
  value       = split("/", var.ipv4_cidr)[0]
}

output "vm_mac" {
  description = "MAC address of net0."
  value       = proxmox_virtual_environment_vm.media_stack.network_device[0].mac_address
}

output "ha_resource" {
  description = "HA resource ID of the VM (`ha-manager status` shows where it runs)."
  value       = proxmox_haresource.media_stack.resource_id
}

output "image_file_id" {
  description = "Volume ID of the Debian 13 cloud image."
  value       = proxmox_download_file.debian13.id
}
