# VM 201 "media-apps": second Debian 13 cloud-init VM for the media apps that do not need the local
# /data disk (Jellyfin, Aurral, Seerr, Prowlarr, FlareSolverr). It mounts /data over NFS from VM 200
# (ansible: media_host role), so the downloaders and their hardlinks stay on VM 200. Same shape as
# VM 200 (main.tf) minus the data disk; kept as separate resources so VM 200's state addresses never
# move. No HA here yet (ha.tf covers VM 200 only).

# The cloud image must be on the node that creates the VM (local:import is per node).
resource "proxmox_download_file" "debian13_apps" {
  node_name    = var.apps_node_name
  datastore_id = var.image_datastore_id
  content_type = "import"
  file_name    = var.image_file_name
  url          = var.image_url
  overwrite    = false

  lifecycle {
    ignore_changes = [url] # see proxmox_download_file.debian13
  }
}

resource "proxmox_virtual_environment_vm" "media_apps" {
  node_name = var.apps_node_name
  vm_id     = var.apps_vm_id
  name      = var.apps_vm_name

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0"]
  on_boot       = true
  started       = true

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }

  cpu {
    type    = "host"
    cores   = var.apps_cpu_cores
    sockets = 1
  }

  memory {
    dedicated = var.apps_memory_mb
    floating  = 0 # balloon: 0
  }

  serial_device {
    device = "socket"
  }

  vga {
    type = "serial0"
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = var.apps_mac_address
  }

  # OS disk only: app configs live in /opt/media-stack/config here, media comes over NFS
  disk {
    interface    = "scsi0"
    datastore_id = var.datastore_id
    import_from  = proxmox_download_file.debian13_apps.id
    size         = var.os_disk_gb
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  initialization {
    datastore_id = var.datastore_id
    interface    = "ide2"
    upgrade      = false # ciupgrade: 0

    dns {
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = var.apps_ipv4_cidr
        gateway = var.ipv4_gateway
      }
    }

    user_account {
      username = var.vm_user
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_file)))]
    }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [disk[0].import_from, node_name] # same reasons as VM 200 (main.tf)
  }
}
