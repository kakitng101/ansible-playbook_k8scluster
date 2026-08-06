# Ansible Kubernetes Cluster Playbooks

This repository contains Ansible playbooks for deploying Kubernetes clusters on Ubuntu and CentOS. The Ubuntu workflow is the current, fully documented path; the CentOS 7 directory contains a legacy deployment based on external load balancers.

> Security notice: all addresses, usernames, passwords, tokens, and credential paths shown below are placeholders. Replace values enclosed in angle brackets locally, keep real secrets out of version control, and prefer SSH keys or Ansible Vault over plaintext passwords.

## Architecture

The current Ubuntu deployment provides:

- three highly available control-plane nodes with stacked etcd by default;
- three worker nodes;
- an optional three-node external etcd cluster;
- a kube-vip virtual API endpoint;
- containerd as the container runtime;
- Calico v3.32.1 in eBPF mode, without kube-proxy;
- VXLAN cross-subnet encapsulation with BGP disabled; and
- metrics-server installed from the bundled Helm chart.

The playbooks currently download x86-64 binaries and target Ubuntu 24.04. Component defaults in the playbooks include Kubernetes 1.36 packages, containerd 2.3.3, runc 1.5.1, nerdctl 2.3.5, Helm 4.2.3, kube-vip 1.2.2, and Calico 3.32.1.

## Repository Layout

```text
.
├── ubuntu/                  # Current Ubuntu HA cluster workflow
│   ├── certs/               # External-etcd certificate templates
│   ├── calico/              # Calico eBPF resource templates
│   ├── metrics-server/      # Bundled metrics-server Helm chart
│   ├── inventory.ini.sample # Sanitized inventory template
│   └── onperm-*.yaml        # Ordered deployment playbooks
├── centos7/                 # Legacy CentOS 7 playbooks and templates
└── base_env_update.sh       # Standalone environment bootstrap reference
```

## Prerequisites

- An Ansible controller with SSH access to every target host
- Ubuntu 24.04 x86-64 on the Kubernetes nodes
- Passwordless sudo, or a sudo password supplied interactively with `-K`
- Unique hostnames, MAC addresses, and product UUIDs
- Synchronized clocks and unrestricted node-to-node communication
- Access to the package repositories and container registries referenced by the playbooks
- TCP 6443 access to the kube-vip endpoint
- UDP 4789 between nodes for VXLAN traffic
- An unused virtual IP on the interface selected for kube-vip

## Configure the Inventory

Work from the Ubuntu directory and create a private inventory from the sample:

```bash
cd ubuntu
cp inventory.ini.sample inventory.ini
```

Use placeholders while sharing configuration publicly:

```ini
[master]
master1 ansible_ssh_host=<CONTROL_PLANE_IP_1> ansible_ssh_user=<SSH_USER> ansible_ssh_pass=<SSH_PASSWORD>
master2 ansible_ssh_host=<CONTROL_PLANE_IP_2> ansible_ssh_user=<SSH_USER> ansible_ssh_pass=<SSH_PASSWORD>
master3 ansible_ssh_host=<CONTROL_PLANE_IP_3> ansible_ssh_user=<SSH_USER> ansible_ssh_pass=<SSH_PASSWORD>

[worker]
worker1 ansible_ssh_host=<WORKER_IP_1> ansible_ssh_user=<SSH_USER> ansible_ssh_pass=<SSH_PASSWORD>
worker2 ansible_ssh_host=<WORKER_IP_2> ansible_ssh_user=<SSH_USER> ansible_ssh_pass=<SSH_PASSWORD>
worker3 ansible_ssh_host=<WORKER_IP_3> ansible_ssh_user=<SSH_USER> ansible_ssh_pass=<SSH_PASSWORD>

[k8s:children]
master
worker

[k8s:vars]
etcd_mode=internal
kube_vip_address=<KUBE_VIP>
kube_vip_port=6443
kube_vip_interface=<NETWORK_INTERFACE>
kube_pod_cidr=<POD_CIDR>
```

Do not commit the populated `inventory.ini`. For production, remove `ansible_ssh_pass` and use `--private-key <SSH_PRIVATE_KEY_PATH>`, or encrypt credentials with Ansible Vault.

Validate the inventory and connectivity before deployment:

```bash
ansible-inventory -i inventory.ini --graph
ansible -i inventory.ini k8s -m ping
```

## Deploy with Internal etcd

Internal, kubeadm-managed etcd is the default. Run the playbooks in order:

```bash
# 1. Prepare the OS, kernel modules, sysctl settings, firewall, and swap.
ansible-playbook -i inventory.ini onperm-1-kernal-init.yaml

# 2. Install containerd, CNI binaries, Kubernetes packages, nerdctl, and Helm.
ansible-playbook -i inventory.ini onperm-2-k8s-componets-init.yaml

# 3. Initialize the first control plane and join the remaining nodes.
ansible-playbook -i inventory.ini onperm-3-k8s-cluster-init.yaml

# 4. Install Calico eBPF networking and metrics-server.
ansible-playbook -i inventory.ini onperm-4-k8s-calico-init.yaml
```

The cluster initialization deliberately skips kube-proxy. Nodes and CoreDNS may remain unready until the Calico playbook completes.

Selected cluster stages can be rerun with tags:

```bash
ansible-playbook -i inventory.ini onperm-3-k8s-cluster-init.yaml --tags k8s_init
ansible-playbook -i inventory.ini onperm-3-k8s-cluster-init.yaml --tags control_plane_join
ansible-playbook -i inventory.ini onperm-3-k8s-cluster-init.yaml --tags worker_join
ansible-playbook -i inventory.ini onperm-3-k8s-cluster-init.yaml --tags validation
```

## Optional External etcd

Set `etcd_mode=external`, add an `[etcd]` inventory group, and replace each endpoint with `<ETCD_IP_n>`. Then run:

```bash
ansible-playbook -i inventory.ini onperm-0-1-cfssl-init.yaml
ansible-playbook -i inventory.ini onperm-0-2-etcd-service-init.yaml
```

Before Kubernetes initialization, securely place the external-etcd client credentials on the first control-plane node:

```text
<ETCD_CA_CERT_PATH>
<ETCD_CLIENT_CERT_PATH>
<ETCD_CLIENT_KEY_PATH>
```

The certificate-generation playbook is intended for initial provisioning, not certificate rotation. Do not rerun it against a live external-etcd cluster unless all dependent certificates will be rotated together.

## Validation

After Calico is installed, run these commands on the first control-plane node:

```bash
kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide
kubectl --kubeconfig=/etc/kubernetes/admin.conf get tigerastatus
kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n calico-system -o wide
kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system -o wide
kubectl --kubeconfig=/etc/kubernetes/admin.conf get daemonset kube-proxy -n kube-system
```

A successful deployment has all nodes in `Ready`, Calico reporting `Available=True`, CoreDNS running, and no kube-proxy DaemonSet. Also test DNS, ClusterIP access, cross-node Pod traffic, and NetworkPolicy behavior before accepting the cluster for production use.

## Legacy CentOS 7 Workflow

The `centos7/` directory contains the older Kubernetes deployment path. It models control-plane, worker, optional storage, and load-balancer roles; API high availability is provided by Keepalived and an NGINX TCP proxy. Review and sanitize `centos7/hosts` and all templates before use. CentOS 7 is end-of-life, so this workflow should be treated as a migration or reference implementation rather than the recommended production path.

## Operational Notes

- Review pinned component versions before every deployment.
- Run `ansible-playbook --syntax-check` on each playbook before changing remote systems.
- Store kubeconfigs, join commands, certificate keys, private keys, and Vault passwords outside the repository.
- The playbooks make system-level changes and should first be tested in a disposable environment.
- See `ubuntu/README.md` for detailed behavior, troubleshooting notes, and worker expansion procedures.
