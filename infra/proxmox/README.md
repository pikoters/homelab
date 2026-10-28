# Proxmox Kubernetes lab

Terraform provisions Ubuntu virtual machines from an existing Proxmox cloud-init
template. Ansible configures the VMs and builds a kubeadm Kubernetes cluster
with one control-plane node by default, configurable workers, containerd,
Flannel networking, and Traefik for ingress. kube-vip, MetalLB, and NFS-backed
persistent storage are optional and disabled by default. Without MetalLB,
Traefik is exposed as a NodePort service.

## Requirements

- Terraform 1.5 or newer.
- Ansible Core 2.15 or newer on the machine running the playbook.
- A Proxmox API token with permissions to clone and configure VMs on the target
  node and datastore.
- An Ubuntu Server 24.04 LTS cloud-init template on Proxmox. It should include
  the QEMU guest agent, a cloud-init drive, and a `scsi0` disk. The template
  must accept cloud-init SSH keys and network configuration.
- A reserved, unused static IPv4 address for each node, all on the same network.
- If enabling kube-vip later, a separate reserved IPv4 address on the
  controllers' Layer 2 network.
- If enabling MetalLB, a non-overlapping range of reserved IPv4 addresses on
  the same Layer 2 network as the Kubernetes nodes. Keep both the kube-vip IP
  and this range outside DHCP.
- If enabling NFS-backed persistent storage, an NFS server and export path
  reachable by every node. The export must allow read/write access from the
  Kubernetes node addresses.
- SSH access to the VMs from the Ansible machine. The SSH host keys should be
  trusted by the machine running Ansible before the playbook connects.

## Configure and provision

1. Copy `terraform/terraform.tfvars.example` to `terraform/terraform.tfvars`.
2. Set the Proxmox endpoint, node, template VM ID, datastore, gateway, and SSH
   key paths. Start with one entry in `controller_nodes`; configure
   `worker_nodes` as needed. Give every VM a unique ID and reserved IP address.
3. Create a Proxmox API token and provide it through the environment. Do not put
   the token in the tfvars file:

   ```sh
   export TF_VAR_proxmox_api_token='user@realm!tokenid=secret'
   ```
4. generate an ssh key

  ```sh
  ssh-keygen -t ed25519
  ```

5. Initialize, inspect, and apply Terraform:

   ```sh
   cd terraform
   terraform init
   terraform plan
   terraform apply
   ```

   Review the plan before applying. `terraform destroy` removes the VMs managed
   by this configuration.

## Configure Kubernetes with Ansible

From the repository root, run the dynamic inventory and playbook after Terraform
has applied successfully:

```sh
cd ansible
ansible-inventory -i inventory/terraform.py --list
ansible-playbook -i inventory/terraform.py site.yml
```

The inventory reads the `nodes` Terraform output, so it uses the same node names,
addresses, and SSH settings as provisioning. With the default
`enable_kube_vip: false`, the controller's own IP is the Kubernetes API
endpoint. Ansible bootstraps the first controller only; any additional
configured controllers remain unjoined until HA is enabled. Configure
`ansible/group_vars/all.yml` before running the playbook:

If inventory reports that Terraform plugins are missing, run `terraform init`
from the `terraform` directory. If the `nodes` output is missing, apply the
Terraform configuration first; the inventory cannot list VMs until Terraform
has created them.

- Set `metallb_address_range` to the reserved address range for Kubernetes
  `LoadBalancer` services and set `enable_metallb: true` to install MetalLB.
  MetalLB announces these addresses over Layer 2. Traefik is then installed as
  a `LoadBalancer` service and receives one of them. The pool must be unused
  and on the same LAN as the Kubernetes nodes.
- By default, `enable_metallb: false`; Traefik is exposed as `NodePort` instead.
  Find the allocated ports with
  `kubectl -n traefik get service traefik`. Access Traefik at
  `<node-ip>:<nodePort>`; the Kubernetes node IP must be reachable by clients.
- NFS-backed persistent storage is disabled by default. To enable it, set
  `enable_nfs_storage: true`, then set `nfs_server` and `nfs_export_path` to
  the NFS server and export. The playbook installs an NFS subdirectory
  provisioner and creates the configured storage class (`nfs-client` by
  default, and default for PVCs unless changed). Its reclaim policy defaults to
  `Retain`, so removing a PVC does not automatically remove the volume data.
- Optionally change the Kubernetes minor version, pod CIDR, Flannel manifest,
  and chart versions. The default pod CIDR is Flannel's `10.244.0.0/16`; ensure
  it does not overlap with your LAN or another routed network.

### Adding high availability later

For a future HA cluster, set `enable_kube_vip: true`, configure a dedicated,
unused `kube_vip_address`, set the controllers' network interface if it differs
from Ansible's detected default-route interface, and add an odd number of
controllers (usually three) to Terraform's `controller_nodes`. kube-vip uses
ARP, so all controller nodes and the VIP must share a Layer 2 network.

**Do not simply turn kube-vip on for a cluster initialized without it.** kubeadm
sets the API endpoint at cluster initialization. Moving that endpoint later
requires a deliberate control-plane migration. For this lab, enable HA as part
of a fresh cluster setup, or plan a deliberate rebuild/migration; Ansible will
not silently join extra controllers to a cluster that has no shared API VIP.

When kube-vip is disabled, Ansible points the controller's admin kubeconfig and
new worker join commands at the controller's own IP. It also updates the
`kubeadm-config` ConfigMap's `controlPlaneEndpoint` before generating join
commands. This allows recovery from an interrupted earlier bootstrap where
kubeadm still recorded a VIP. Enabling HA later still requires a planned
control-plane migration or rebuild.

To completely replace a disposable cluster, destroy and recreate all
Terraform-managed VMs before rerunning Ansible:

```sh
cd terraform
terraform destroy
terraform apply
cd ../ansible
ansible-playbook -i inventory/terraform.py site.yml
```

### SSH host key verification

Ansible host key checking is enabled. Before its first connection to each new
VM, verify the SSH host key fingerprint using the VM console in Proxmox and add
the verified key to the machine running Ansible. The dynamic inventory uses
each VM's IP address as its SSH host:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
ssh-keyscan -t ed25519 <node-ip> 2>/dev/null | ssh-keygen -lf -
```

Compare the fingerprints from the VM console and `ssh-keyscan`. Only if they
match, add that VM's key:

```sh
ssh-keyscan -H -t ed25519 <node-ip> >> ~/.ssh/known_hosts
```

Repeat for each node, then rerun the Ansible playbook. If an IP was reused and
has an old known-hosts entry, first verify the VM's new fingerprint through the
Proxmox console, then remove only that IP's stale entry with
`ssh-keygen -R <node-ip>` and add the verified key as above. Do not turn off
host key checking or trust `ssh-keyscan` output without verifying its
fingerprint.

If all cloned VMs report the same host key fingerprint, the template likely
contained pre-generated SSH host keys. Clean/rebuild the template so cloud-init
generates unique host keys on first boot, then recreate the VMs. Do not accept
the same key for every VM as a workaround.

After the playbook completes, use the SSH account configured by
`ssh_username` in Terraform to check the cluster and discover Traefik's
address:

```sh
ssh <ssh-user>@<controller-ip> kubectl get nodes -o wide
ssh <ssh-user>@<controller-ip> kubectl -n traefik get service traefik
```

Point DNS names for your ingress routes at Traefik's external IP. When NFS
storage is enabled, applications can request persistent storage using a PVC
with `storageClassName: nfs-client` (or omit the field when that storage class
is configured as default). The NFS provisioner creates a subdirectory per
volume on the configured export.

The playbook installs `kubectl` on the control-plane nodes and copies the admin
kubeconfig to the SSH user's actual home directory at `~/.kube/config`
(`ansible_user_dir`), including when the SSH user is `root`. This admin config
grants cluster-administrator access; keep it private. To use `kubectl` directly
from your workstation, securely copy the kubeconfig from the control-plane VM
and protect the local copy; its server address must be reachable from your
workstation.

## Notes

- Terraform keeps state in its default local backend. Do not share or commit
  `terraform.tfstate`; it can contain infrastructure details and secrets.
- The Proxmox API token is marked sensitive by Terraform, but shell history and
  process environments should still be handled carefully.
- The default Kubernetes apt repository tracks the configured minor release
  stream. For a long-lived cluster, pin package versions and plan upgrades
  deliberately.
- NFS-backed volumes depend on the availability and backup policy of the
  external NFS server. They do not replicate data within Kubernetes.
- kube-vip and MetalLB use Layer 2 ARP announcements and are intended for a
  single local network, not routed cross-subnet load balancing.
- This is a lab bootstrap, not a hardened production design. It does not
  configure firewall rules, backups, TLS certificates, or production ingress
  policies.
