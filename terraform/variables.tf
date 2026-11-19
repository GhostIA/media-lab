variable "node_name" {
  description = "PVE node that runs VM 200 and holds the cloud image."
  type        = string
  default     = "intel-a163f8"
}

variable "vm_id" {
  description = "VMID of the media stack VM."
  type        = number
  default     = 200
}

variable "vm_name" {
  description = "VM name (also the hostname set by cloud-init)."
  type        = string
  default     = "media-stack"
}

variable "datastore_id" {
  description = "PVE storage for the VM disks and the cloud-init drive (Ceph RBD, EC 2+1)."
  type        = string
  default     = "media-ec"
}

variable "image_datastore_id" {
  description = "PVE storage with content type 'import' that holds the cloud image."
  type        = string
  default     = "local"
}

variable "image_url" {
  description = "Debian 13 (trixie) genericcloud amd64 qcow2."
  type        = string
  default     = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
}

variable "image_file_name" {
  description = "File name of the cloud image in <image_datastore_id>:import/."
  type        = string
  default     = "debian-13-genericcloud-amd64.qcow2"
}

variable "cpu_cores" {
  description = "vCPUs (one socket, CPU type host)."
  type        = number
  default     = 4
}

variable "memory_mb" {
  description = "Dedicated memory in MiB (no ballooning)."
  type        = number
  default     = 5120
}

variable "os_disk_gb" {
  description = "OS disk (scsi0) size in GiB. Can only grow."
  type        = number
  default     = 32
}

variable "data_disk_gb" {
  description = "Data disk (scsi1, ext4 /data) size in GiB. Can only grow."
  type        = number
  default     = 3072
}

variable "mac_address" {
  description = "MAC of net0 (pinned so the guest keeps its interface identity)."
  type        = string
  default     = "BC:24:11:1D:86:A5"
}

variable "ipv4_cidr" {
  description = "Static IPv4 address of the VM in CIDR notation."
  type        = string
  default     = "192.168.8.200/24"
}

variable "ipv4_gateway" {
  description = "Default gateway."
  type        = string
  default     = "192.168.8.1"
}

variable "dns_servers" {
  description = "DNS servers set by cloud-init."
  type        = list(string)
  default     = ["192.168.8.1"]
}

variable "dns_domain" {
  description = "DNS search domain set by cloud-init."
  type        = string
  default     = "home.arpa"
}

variable "vm_user" {
  description = "cloud-init user (uid 1000, owns the stack)."
  type        = string
  default     = "media"
}

variable "ssh_public_key_file" {
  description = "Public key installed for vm_user by cloud-init."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
