variable "proxmox_api_url" {
  description = "Proxmox API endpoint, for example https://pve.example:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token in user@realm!tokenid=secret format."
  type        = string
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS certificate verification. Prefer trusting the Proxmox CA instead."
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node on which to clone the VMs."
  type        = string
}

variable "template_vm_id" {
  description = "VM ID of the Ubuntu 24.04 cloud-init template."
  type        = number
}

variable "datastore_id" {
  description = "Proxmox datastore used for the VM disks."
  type        = string
}

variable "network_bridge" {
  description = "Proxmox bridge connected to the node network."
  type        = string
  default     = "vmbr0"
}

variable "gateway" {
  description = "IPv4 gateway for all Kubernetes nodes."
  type        = string
}

variable "dns_servers" {
  description = "DNS servers configured through cloud-init."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "ssh_username" {
  description = "Cloud-init user created on each VM."
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key_file" {
  description = "Path to the SSH public key to install on each VM."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_file" {
  description = "Path to the matching private key, used by Ansible."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "controller_nodes" {
  description = "Kubernetes control-plane VMs. The first entry bootstraps the cluster; use an odd count for etcd quorum."
  type = list(object({
    name         = string
    vm_id        = number
    ipv4_address = string
    cores        = number
    memory_mb    = number
    disk_gb      = number
  }))

  validation {
    condition     = length(var.controller_nodes) >= 1
    error_message = "At least one control-plane VM is required."
  }
}

variable "worker_nodes" {
  description = "Kubernetes worker VMs. An empty list provisions no workers."
  type = list(object({
    name         = string
    vm_id        = number
    ipv4_address = string
    cores        = number
    memory_mb    = number
    disk_gb      = number
  }))
  default = []
}

locals {
  nodes = merge(
    {
      for index, node in var.controller_nodes :
      node.name => merge(node, {
        role = index == 0 ? "controllers_primary" : "controllers_additional"
      })
    },
    {
      for node in var.worker_nodes :
      node.name => merge(node, { role = "workers" })
    }
  )
}
