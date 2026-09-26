# CentOS 7 Kubernetes Deployment Guide

This directory contains Ansible playbooks for deploying a Kubernetes cluster
on CentOS 7 with containerd. The cluster uses multiple control-plane nodes,
worker nodes, and separate NGINX/Keepalived load balancers for a shared API
virtual IP (VIP).

## 1. Prepare the environment

You need:

- CentOS 7 x86-64 servers with unique hostnames and working name resolution.
- An Ansible controller with SSH access and root or sudo permissions on all servers.
- Working package repositories and access to the required container images.
- A reserved VIP and network interface for the load balancers.
- Network connectivity between all nodes and synchronized system clocks.

Run the following commands from the `centos7` directory:

```bash
cd centos7
```

## 2. Configure the inventory

Edit `hosts` with your server addresses and SSH settings. Keep the
`master1`, `master2`, and `master3` names because the playbooks reference them.

| Inventory group | Purpose |
| --- | --- |
| `master` | Kubernetes control-plane nodes. |
| `worker` | Kubernetes worker nodes. |
| `storage` | Optional additional worker nodes; storage software is installed separately. |
| `k8s` | Includes `master`, `worker`, and `storage`. |
| `lb` | NGINX and Keepalived load-balancer nodes. |

Example host entry:

```ini
[master]
master1 ansible_ssh_host=<MASTER_1_IP> ansible_user=<SSH_USER>
master2 ansible_ssh_host=<MASTER_2_IP> ansible_user=<SSH_USER>
master3 ansible_ssh_host=<MASTER_3_IP> ansible_user=<SSH_USER>
```

Use SSH keys or Ansible Vault for credentials. Check the inventory and connectivity:

```bash
ansible-inventory -i hosts --graph
ansible -i hosts all -m ping
```

## 3. Prepare deployment configuration

Before running the playbooks, adapt their host targets, file paths, and
site-specific values for your environment:

- Set the API endpoint in `4.master-1.yaml` to your load-balancer `VIP:6443`.
- Configure the VIP, interface, and Keepalived states/priorities in
  `keepalived.conf.j2` and the inventory.
- Configure the control-plane upstream addresses in `k8s.conf.j2`.
- Configure the load-balancer plays to target the `lb` group.
- Review package repositories and versions. The Kubernetes package play uses
  the `v1.32` repository; the kernel play installs version `6.7.2`.

Some playbooks copy files from fixed paths on the **Ansible controller**.
Prepare those files, or change their source paths in the playbooks:

| Controller path | Source / purpose |
| --- | --- |
| `/etc/hosts` | Hostname mappings copied to Kubernetes nodes. |
| `/etc/yum.repos.d/CentOS-Base.repo` | CentOS package repository configuration. |
| `/tmp/containerd.service` | Bundled `containerd.service`. |
| `/tmp/nginx.conf` | Reviewed `nginx.conf`. |
| `/tmp/k8s.conf` | API proxy configuration based on `k8s.conf.j2`. |
| `/tmp/keepalived.conf.j2` | Reviewed `keepalived.conf.j2`. |

The active cluster initialization play generates its kubeadm configuration;
it does not read `cluster.yaml.j2`.

## 4. Deploy the cluster

Run the adapted playbooks in the order below. The examples use `-b` for sudo;
add `-K` if sudo requires a password.

### Prepare Kubernetes nodes

The kernel step updates packages and reboots the nodes. Wait for them to
return before continuing.

```bash
ansible-playbook -i hosts -b 0.kernel_update.yaml
ansible -i hosts k8s -m wait_for_connection -a 'timeout=600'
ansible -i hosts k8s -m command -a 'uname -r'

ansible-playbook -i hosts -b 1.init.yaml
ansible-playbook -i hosts -b 2.containerd.yaml
ansible-playbook -i hosts -b 3.k8s-cluster.yaml
```

These steps prepare the OS, disable swap and firewalld on Kubernetes nodes,
install containerd, and install kubelet, kubeadm, and kubectl.

### Prepare API load balancing

Prepare the LB servers' OS and package repositories separately, then deploy
NGINX and Keepalived **before** initializing the cluster:

```bash
ansible-playbook -i hosts -b 5.1.k8s-lb.yaml
ansible -i hosts lb -b -m command -a 'nginx -t'
ansible -i hosts lb -b -m command -a 'systemctl is-active nginx keepalived'
```

Confirm the VIP is assigned to a load balancer and reachable from the nodes.
API traffic goes through the VIP on port 6443 to the control-plane nodes.

### Initialize Kubernetes and join nodes

```bash
ansible-playbook -i hosts -b 4.master-1.yaml
```

This playbook initializes `master1`, joins `master2` and `master3` as control
planes, and joins the `worker` and `storage` groups as workers. It places the
admin kubeconfig at `/root/.kube/config` on `master1`.

### Install cluster networking

Install your chosen Kubernetes CNI separately; these playbooks do not
install a network plugin. Match its Pod network to the initialization
playbook's `10.244.0.0/16` CIDR, or adjust that CIDR before deployment.

For a manifest-based installation, run on `master1` as root, replacing the path:

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl apply -f /path/to/your-cni-manifest.yaml
```

## 5. Verify the cluster

Run on `master1` with the admin kubeconfig:

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl -n kube-system get daemonset kube-proxy
kubectl get --raw='/readyz'
```

Confirm all nodes become `Ready`, CoreDNS and the network plugin are running,
and Pod networking and DNS work. Nodes may remain unready until the CNI is
installed. Also verify API access through the VIP and load-balancer failover.

## 6. Add a worker node

`6.node_join.yaml` and `8.node_join.yaml` provide the same join workflow for
hosts in the `storage` group. Add the new node to that group, prepare it,
and run one of the join playbooks. For example, for `storage4`:

```bash
ansible-playbook -i hosts -b 0.kernel_update.yaml --limit storage4
ansible -i hosts storage4 -m wait_for_connection -a 'timeout=600'
ansible-playbook -i hosts -b 1.init.yaml --limit storage4
ansible-playbook -i hosts -b 2.containerd.yaml --limit storage4
ansible-playbook -i hosts -b 3.k8s-cluster.yaml --limit storage4
ansible-playbook -i hosts -b 6.node_join.yaml --limit master1,storage4
```

Include `master1` in the join command's limit because it generates the join
credentials. To use this helper for the `worker` group, adapt its join target.

## 7. Optional tools

| File | Purpose |
| --- | --- |
| `7.nerdctl_get.yaml` | Install nerdctl on control-plane nodes. |
| `9.nerdctl_get.yaml` | Install nerdctl on all Kubernetes nodes and Helm on control-plane nodes. |
| `10.buildkit.yaml` | Install BuildKit on Kubernetes nodes. |
| `13.containerd_cert.yaml` | Configure registry mirrors for selected hosts after adapting its target and runtime configuration. |
| `5.2.lb_test.yaml` | Optional load-balancer HTTP test configuration. |
| `kp.yaml`, `lb-test.yaml` | Helper playbooks for rendering or deploying load-balancer configuration. |
| `rolebind.yaml` | Kubernetes RBAC manifest for an existing `k8s-tls-deploy` ServiceAccount. |
| `kube_config_output.sh` | Create a deployment ServiceAccount, RBAC permissions, and a token-based kubeconfig. |
| `Jenkinsfile_with_docker_images` | Separate example application build/deployment pipeline. |

For nerdctl, place `nerdctl-2.0.3-linux-amd64.tar.gz` in the controller's
`/tmp` directory. For BuildKit, stage `buildkit-v0.20.0.linux-amd64.tar.gz`,
plus `11.buildkit.service` as `/tmp/buildkit.service` and
`12.buildkit.socket` as `/tmp/buildkit.socket`.

```bash
# Optional: nerdctl and Helm.
ansible-playbook -i hosts -b 9.nerdctl_get.yaml

# Optional: BuildKit, after staging its archive and service files.
ansible-playbook -i hosts -b 10.buildkit.yaml
```

Treat kubeconfigs and join-command output as credentials. Initialization and
join playbooks are intended for new nodes; do not rerun them as an upgrade
procedure on an existing cluster.
