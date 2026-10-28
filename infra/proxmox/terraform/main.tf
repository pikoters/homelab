resource "proxmox_virtual_environment_vm" "node" {
  for_each  = local.nodes
  name      = each.value.name
  vm_id     = each.value.vm_id
  node_name = var.proxmox_node
  tags      = ["kubernetes", "terraform", each.value.role]

  clone {
    vm_id = var.template_vm_id
    full  = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = each.value.disk_gb
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  initialization {
    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = each.value.ipv4_address
        gateway = var.gateway
      }
    }

    user_account {
      username = var.ssh_username
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_file)))]
    }
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    precondition {
      condition     = length(distinct([for node in values(local.nodes) : node.vm_id])) == length(local.nodes)
      error_message = "Every Kubernetes VM must have a unique Proxmox VM ID."
    }

    precondition {
      condition     = length(distinct([for node in values(local.nodes) : split("/", node.ipv4_address)[0]])) == length(local.nodes)
      error_message = "Every Kubernetes VM must have a unique IPv4 address."
    }
  }
}
