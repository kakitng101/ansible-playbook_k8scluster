# Hardware requirements

| Node Info | CPU | Memory | DISK | Interface |COUNT|
| --- | --- | --- | --- | --- |---|
|k8s-master|8|16Gi|300Gi|Optical Module * 2 | 3 |
|k8s-worker|8|16Gi|300Gi|Optical Module * 2 | 13 |
|k8s-storage(optional)|8|16Gi|Total 3 Ti(total 9 disks)| Optical Module *2 | 3|
|k8s-lb| 2 | 4Gi | 100Gi | Optical Module *2| 3|
|NAS|32|64Gi|500Ti|-|1|
|Optical Switch|- | -|-|24\|48 Optical port in 10\|25 Gbps|2|


# Software requirements

| Components | Node | Usage |
| --- | ---|---|
|api-server| master| k8s api endpoints|
|controller| master| k8s pod lifecycle control|
|scheduler| master | k8s resource detect and schedule|
|etcd | master |k8s core metadata storage|
|coredns | master | k8s FQDN nameserver |
|kube-proxy| All(optional) | k8s traffic proxy |
|node-local-dns| Local Host | k8s node dns cache|
|cilium \| calico| ALL | k8s internal CNI for network|
|rook-ceph| storage | k8s internal storage |
|istio | ALL | k8s inbond and service mesh |
|cert-manager | worker | automate certificate update |
|kube-prometheus-stack| worker| k8s basic monitor |
|alloy+loki-stack| All | k8s logs collector |
|grafana | worker | graphic showing tools |

# Middlewave requirements

| Name | Usage | HA |
| --- | --- | --- |
|Postgresql | Project database center | Read write seperate |
|kafka | Message Queue | 3 * controller + 3 * broker |
|Mongodb | doc database center | 1 * primary + 1 * secondary + 1 * arbitration |
|Keycloak | SSO-Oauth2 | - |
|Temporal |   |  - |
|OpenFGA | RBAC | -|
|Starrocks| Analytic database | 3 * FE + 3 * BE |
|Thingsboard| IoT platform | - |
|Superset | BI platform | -|
|Nifi | graphical ETL| -|
|Debezium| CDC platform | -|
|redis | caching database | 6 * cluster |

# Monitoring requirements

| Componets | Node | Usage |
| --- | --- | --- |
|node_exporter| ALL | Host node info resources detect|
|prometheus-adaptor| worker | Customize metrics for service |
|blackbox_exporter(optional)| worker | api quality detect|
|pm-alertmanager | worker | alert push gateway |


# Kubernetes Cluster Deployment with Ansible

This project installs a highly available Kubernetes cluster on Ubuntu 24.04 with three control-plane nodes and three worker nodes.

The default topology uses stacked etcd, with one kubeadm-managed etcd member on each control-plane node. Optional external etcd support is retained for future use. Calico v3.32.1 is installed by the Tigera Operator in eBPF mode, and kube-proxy is not deployed.

## Cluster Topology

The example inventory defines the following nodes:

| Role | Hosts | Addresses |
|---|---|---|
| Control plane | `master1`, `master2`, `master3` | `192.168.10.11-13` |
| Worker | `worker1`, `worker2`, `worker3` | `192.168.10.4-6` |
| Optional external etcd | `etcd1`, `etcd2`, `etcd3` | `192.168.10.21-23` |

Review `inventory.ini` before deployment. In particular, verify these values:

```ini
etcd_mode=internal
kube_vip_address=192.168.10.10
kube_vip_port=6443
kube_vip_interface=eth0
kube_pod_cidr=10.244.0.0/16
```

The kube-vip address must be unused, reachable from every Kubernetes node, and on the interface configured by `kube_vip_interface`. The example addresses are placeholders and must be replaced before a real deployment.

## Deployment Design

- Kubernetes uses a highly available API endpoint provided by kube-vip.
- kubeadm skips the `addon/kube-proxy` phase.
- Calico uses the eBPF data plane and implements Kubernetes Service handling.
- Calico reaches the API server directly through `kube_vip_address:kube_vip_port` instead of relying on the Kubernetes Service ClusterIP during bootstrap.
- The Pod CIDR is `10.244.0.0/16` by default.
- The Calico IP pool uses `VXLANCrossSubnet`; traffic between nodes in the same underlay subnet is not VXLAN-encapsulated, while cross-subnet traffic is encapsulated.
- BGP is disabled because this deployment does not advertise workload routes to external routers.
- Standard CNI binaries remain installed in `/opt/cni/bin`; Calico adds its own CNI binaries and configuration.

## Prerequisites

- Ubuntu 24.04 on all Kubernetes nodes.
- x86-64 processors. The downloaded binaries are currently pinned to `linux-amd64` builds.
- SSH access from the Ansible controller to every target node.
- A remote user with passwordless sudo, or the sudo password available for `-K`.
- Unique hostnames, MAC addresses, and product UUIDs.
- Time synchronization and full network connectivity between all nodes.
- Internet or mirror access for GitHub, `pkgs.k8s.io`, `registry.k8s.io`, `ghcr.io`, `quay.io`, and the Calico image registries.
- TCP 6443 connectivity to the kube-vip API endpoint.
- UDP 4789 connectivity between Kubernetes nodes for VXLAN traffic.
- A network that permits direct node-to-node workload traffic when using `VXLANCrossSubnet`. Check hypervisor or cloud anti-spoofing restrictions before deployment.

Run all commands from the project directory:

```bash
cd /home/kk/project/ansible-playbook-k8s-init
```

## Validate the Configuration

Inspect the inventory hierarchy:

```bash
ansible-inventory -i inventory.ini --graph
```

Verify connectivity to the six Kubernetes nodes:

```bash
ansible -i inventory.ini k8s -m ping
```

If external etcd will be used, verify those nodes as well:

```bash
ansible -i inventory.ini etcd -m ping
```

Run syntax checks before making remote changes:

```bash
ansible-playbook -i inventory.ini --syntax-check onperm-0-1-cfssl-init.yaml
ansible-playbook -i inventory.ini --syntax-check onperm-0-2-etcd-service-init.yaml
ansible-playbook -i inventory.ini --syntax-check onperm-1-kernal-init.yaml
ansible-playbook -i inventory.ini --syntax-check onperm-2-k8s-componets-init.yaml
ansible-playbook -i inventory.ini --syntax-check onperm-3-k8s-cluster-init.yaml
ansible-playbook -i inventory.ini --syntax-check onperm-4-k8s-calico-init.yaml
```

## Default Installation: Internal etcd

The default inventory sets `etcd_mode=internal`. Do not run the `0-1` or `0-2` external-etcd playbooks in this mode. The cluster initialization playbook only accepts `internal` and `external` as etcd modes.

### 1. Prepare the operating system

This playbook disables swap and UFW, installs the required packages, loads the Kubernetes networking kernel modules, and applies the required sysctl settings on all six Kubernetes nodes. IPVS is intentionally not configured.

```bash
ansible-playbook -i inventory.ini onperm-1-kernal-init.yaml
```

### 2. Install the runtime and Kubernetes packages

This playbook installs containerd, runc, standard CNI plugin binaries, nerdctl, kubelet, kubeadm, kubectl, and Helm. It enables systemd cgroups and holds the Kubernetes packages to prevent unintended upgrades.

```bash
ansible-playbook -i inventory.ini onperm-2-k8s-componets-init.yaml
```

### 3. Initialize the Kubernetes cluster

This playbook:

- creates the kubeadm configuration on the first host in the `master` inventory group;
- configures the kube-vip control-plane endpoint;
- initializes Kubernetes with `--skip-phases=addon/kube-proxy`;
- joins the remaining hosts in the `master` group sequentially;
- joins all three worker nodes sequentially;
- verifies that six nodes and three control-plane nodes are registered.

```bash
ansible-playbook -i inventory.ini onperm-3-k8s-cluster-init.yaml
```

The initialization and node-join stages can also be rerun independently. Existing nodes are protected by kubeadm's generated files, so these commands skip an already initialized or joined node:

```bash
ansible-playbook -i inventory.ini onperm-3-k8s-cluster-init.yaml --tags k8s_init
ansible-playbook -i inventory.ini onperm-3-k8s-cluster-init.yaml --tags control_plane_join
ansible-playbook -i inventory.ini onperm-3-k8s-cluster-init.yaml --tags worker_join
ansible-playbook -i inventory.ini onperm-3-k8s-cluster-init.yaml --tags validation
```

The playbook also configures `/root/.kube/config` on the first host in the `master` group for subsequent kubectl operations.

Before Calico is installed, it is expected that:

- the nodes report `NotReady`;
- CoreDNS Pods remain `Pending`;
- ClusterIP Services do not work because kube-proxy is not present; and
- host-networked control-plane components remain accessible.

Inspect the pre-CNI state on `master1`:

```bash
kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide
kubectl --kubeconfig=/etc/kubernetes/admin.conf \
  get pods -n kube-system -l component=etcd -o wide
kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw='/readyz?verbose'
```

### 4. Install Calico in eBPF mode

This playbook:

- renders a direct API endpoint ConfigMap using the kube-vip address;
- applies the Calico v3.32.1 CRDs with server-side apply;
- waits for the required CRDs to become established;
- installs and waits for the Tigera Operator;
- applies the Calico `Installation`, `APIServer`, `Goldmane`, and `Whisker` resources;
- waits for the core Calico installation to become available; and
- verifies that all six Kubernetes nodes report `Ready`.

```bash
ansible-playbook -i inventory.ini onperm-4-k8s-calico-init.yaml
```

The direct API endpoint ConfigMap and Calico Installation are rendered from:

```text
calico/kubernetes-services-endpoint.yaml.j2
calico/custom-resources.yaml.j2
```

Do not enable `bpfNetworkBootstrap` while the manually managed `kubernetes-services-endpoint` ConfigMap is present. `kubeProxyManagement` is also unnecessary because kube-proxy is never created.

## Optional External etcd Installation

Use this path only when `etcd_mode=external`. External etcd is optional and is not used by the default deployment.

### 0-1. Generate the external-etcd certificates

This playbook installs CFSSL tools on the Ansible controller and generates the CA and per-member certificates under `/opt/certs` on the controller.

```bash
ansible-playbook -i inventory.ini onperm-0-1-cfssl-init.yaml
```

The CA generation task is not a certificate-rotation workflow. Do not rerun it against an active external-etcd deployment unless all dependent certificates will be replaced together.

### 0-2. Install the external-etcd services

This playbook installs etcd on the three hosts, distributes their certificates, enables the systemd service, and checks each local endpoint.

```bash
ansible-playbook -i inventory.ini onperm-0-2-etcd-service-init.yaml
```

Before changing the inventory to external mode, verify the complete etcd cluster from an etcd node:

```bash
ETCDCTL_API=3 etcdctl \
  --endpoints=https://192.168.10.21:2379,https://192.168.10.22:2379,https://192.168.10.23:2379 \
  --cacert=/etc/etcd/pki/ca.pem \
  --cert=/etc/etcd/pki/etcd.pem \
  --key=/etc/etcd/pki/etcd-key.pem \
  endpoint status --cluster -w table
```

The helper playbooks do not automatically copy the kube-apiserver etcd client credentials to `master1`. Before running the Kubernetes cluster initialization, place these files on `master1`:

```text
/etc/kubernetes/pki/etcd/ca.crt
/etc/kubernetes/pki/apiserver-etcd-client.crt
/etc/kubernetes/pki/apiserver-etcd-client.key
```

Then update the inventory:

```ini
etcd_mode=external
```

Run the Kubernetes installation stages normally:

```bash
ansible-playbook -i inventory.ini onperm-1-kernal-init.yaml
ansible-playbook -i inventory.ini onperm-2-k8s-componets-init.yaml
ansible-playbook -i inventory.ini onperm-3-k8s-cluster-init.yaml
ansible-playbook -i inventory.ini onperm-4-k8s-calico-init.yaml
```

The cluster initialization playbook validates the etcd mode as either `internal` or `external`. When external mode is selected, kubeadm will validate the configured endpoints and client credentials during initialization.

## Post-installation Validation

Run these commands on `master1` after Stage 4:

```bash
kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide
kubectl --kubeconfig=/etc/kubernetes/admin.conf get tigerastatus
kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n calico-system -o wide
kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -n kube-system -o wide
kubectl --kubeconfig=/etc/kubernetes/admin.conf \
  rollout status deployment/coredns -n kube-system --timeout=300s
```

Confirm that kube-proxy was not deployed:

```bash
kubectl --kubeconfig=/etc/kubernetes/admin.conf \
  get daemonset kube-proxy -n kube-system
```

The expected result is `NotFound`.

Confirm the manually configured Calico API endpoint:

```bash
kubectl --kubeconfig=/etc/kubernetes/admin.conf \
  get configmap kubernetes-services-endpoint \
  -n tigera-operator -o yaml
```

The installation is structurally successful when:

- all six nodes report `Ready`;
- the core Calico TigeraStatus is `Available=True`;
- Calico node Pods run on all six nodes;
- CoreDNS is running and available; and
- no kube-proxy DaemonSet exists.

Before accepting the cluster for production workloads, also test:

- DNS resolution from a Pod;
- Kubernetes ClusterIP Service access;
- Pod-to-Pod traffic on the same node;
- Pod-to-Pod traffic across nodes in the same underlay subnet;
- Pod-to-Pod traffic across underlay subnets, if applicable; and
- NetworkPolicy deny and allow behavior.

Static syntax validation cannot replace these tests on real nodes.

## SSH and Sudo Options

If the SSH user differs from the local user, specify it with `-u` and, when required, provide a private key:

```bash
ansible-playbook -i inventory.ini \
  -u ubuntu \
  --private-key ~/.ssh/id_rsa \
  onperm-1-kernal-init.yaml
```

If sudo requires a password, add `-K`:

```bash
ansible-playbook -i inventory.ini \
  -u ubuntu \
  -K \
  onperm-1-kernal-init.yaml
```

Use the same SSH and sudo options for every applicable playbook.

## Adding a Worker Node

The following example adds a new worker named `worker4`. Replace its address and
SSH credentials with the values for the new host.

First, add the node to the `[worker]` group in the Ansible inventory. If this
repository is using `/root/.ansible/hosts`, add an entry similar to:

```ini
[worker]
worker1 ansible_ssh_host=192.168.122.22 ansible_ssh_user=ubuntu ansible_ssh_pass=123456
worker2 ansible_ssh_host=192.168.122.122 ansible_ssh_user=ubuntu ansible_ssh_pass=123456
worker3 ansible_ssh_host=192.168.122.197 ansible_ssh_user=ubuntu ansible_ssh_pass=123456
worker4 ansible_ssh_host=192.168.122.210 ansible_ssh_user=ubuntu ansible_ssh_pass=123456
```

Confirm that Ansible recognizes the new inventory host and can connect to it:

```bash
ansible-inventory -i ~/.ansible/hosts --graph
ansible -i ~/.ansible/hosts worker4 -m ping
```

Initialize only the new worker's operating system and Kubernetes components:

```bash
ansible-playbook -v -i ~/.ansible/hosts \
  onperm-1-kernal-init.yaml \
  --limit worker4

ansible-playbook -v -i ~/.ansible/hosts \
  onperm-2-k8s-componets-init.yaml \
  --limit worker4
```

The `-i` option is required when the inventory path is supplied explicitly.
Without it, `~/.ansible/hosts` is interpreted as a playbook rather than an
inventory file.

Generate a fresh worker join command on the first host in the `[master]` group:

```bash
ansible -i ~/.ansible/hosts master1 -b \
  -m command \
  -a 'kubeadm token create --print-join-command'
```

Copy the complete `kubeadm join ...` command from the output and execute it on
the new worker:

```bash
ansible -i ~/.ansible/hosts worker4 -b \
  -m shell \
  -a 'kubeadm join 192.168.122.250:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>'
```

Alternatively, the cluster playbook can generate the token on `master1` and use
it to join `worker4` in one invocation:

```bash
ansible-playbook -v -i ~/.ansible/hosts \
  onperm-3-k8s-cluster-init.yaml \
  --tags worker_join \
  --limit 'master1,worker4'
```

The limit must include both the first host in the `[master]` group and the new
worker. The first master generates and registers the join command, while only
`worker4` runs the worker join task. Other master and worker hosts are excluded
by `--limit`. The generated token is stored in the registered Ansible variable
`node_join_output`, so its value is not printed by the playbook.

Finally, verify the new node from the first control-plane host:

```bash
ansible -i ~/.ansible/hosts master1 -b \
  -m command \
  -a 'kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide'
```

The new node can initially report `NotReady` while Calico starts on it. It should
change to `Ready` after the networking Pod is running. If `master1` is not the
first entry in the inventory's `[master]` group, substitute the actual first
inventory hostname in all commands above.
