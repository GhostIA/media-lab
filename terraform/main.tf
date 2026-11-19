# VM 200 "media-stack": Debian 13 cloud-init VM for the *arr media stack, disks on Ceph (media-ec).
# Auth comes from the environment (see .env.op and README.md); no SSH is needed for these resources.
provider "proxmox" {}

# The Debian 13 cloud image in local:import/ on the VM's node. Only used to create scsi0.
resource "proxmox_download_file" "debian13" {
  node_name    = var.node_name
  datastore_id = var.image_datastore_id
  content_type = "import"
  file_name    = var.image_file_name
  url          = var.image_url

  # ".../latest/" moves with every Debian point release; never re-download (and replace) the
  # image just because upstream changed. The VM does not depend on it after creation.
  overwrite = false

  lifecycle {
    # PVE cannot report where a file was downloaded from: after an import url is null in state,
    # and a url diff forces a re-download (replacement). It only matters when the file is created.
    ignore_changes = [url]
  }
}

resource "proxmox_virtual_environment_vm" "media_stack" {
  node_name = var.node_name
  vm_id     = var.vm_id
  name      = var.vm_name

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
    cores   = var.cpu_cores
    sockets = 1
  }

  memory {
    dedicated = var.memory_mb
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
    mac_address = var.mac_address
  }

  # OS disk, imported from the cloud image at creation
  disk {
    interface    = "scsi0"
    datastore_id = var.datastore_id
    import_from  = proxmox_download_file.debian13.id
    size         = var.os_disk_gb
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  # data disk (ext4 /data inside the guest, formatted by the media_host Ansible role)
  disk {
    interface    = "scsi1"
    datastore_id = var.datastore_id
    size         = var.data_disk_gb
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
        address = var.ipv4_cidr
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
    # import_from is a creation-time instruction (copy the cloud image into a new scsi0);
    # PVE does not keep it in the VM config, so it can never be read back.
    ignore_changes = [disk[0].import_from]
  }
}
