output "nodes" {
  description = "Node metadata consumed by the Terraform-backed Ansible inventory."
  value = {
    for name, node in local.nodes : name => {
      name                 = node.name
      role                 = node.role
      ipv4_address         = split("/", node.ipv4_address)[0]
      ssh_username         = var.ssh_username
      ssh_private_key_file = pathexpand(var.ssh_private_key_file)
    }
  }
}
