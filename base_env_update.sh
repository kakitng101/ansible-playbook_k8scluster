## ipvs模式配置

sudo sh -c 'cat << EOF > /etc/modules-load.d/ipvs.conf
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_lc
ip_vs_wlc
ip_vs_lblc
ip_vs_lblcr
ip_vs_sh
ip_vs_dh
ip_vs_sed
ip_vs_nq
nf_conntrack
EOF'

sudo modprobe ip_vs
sudo modprobe ip_vs_rr
sudo modprobe ip_vs_wrr
sudo modprobe ip_vs_lc
sudo modprobe ip_vs_wlc
sudo modprobe ip_vs_lblc
sudo modprobe ip_vs_lblcr
sudo modprobe ip_vs_sh
sudo modprobe ip_vs_dh
sudo modprobe ip_vs_sed
sudo modprobe ip_vs_nq
sudo modprobe nf_conntrack

## helm 安装
wget https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz

## runc 安装
wget https://github.com/opencontainers/runc/releases/download/v1.4.0-rc.2/runc.amd64 && sudo install -m 755 runc.amd64 /usr/local/sbin/runc

[Unit]
Description=Start My Container

[Service]
Type=forking
ExecStart=/usr/local/sbin/runc run -d --pid-file /run/mycontainerid.pid mycontainerid
ExecStopPost=/usr/local/sbin/runc delete mycontainerid
WorkingDirectory=/mycontainer
PIDFile=/run/mycontainerid.pid

[Install]
WantedBy=multi-user.target

## cni-plugins 安装
wget https://github.com/containernetworking/plugins/releases/download/v1.8.0/cni-plugins-linux-amd64-v1.8.0.tgz && mkdir -p /opt/cni/bin && tar -C /opt/cni/bin -xzf cni-plugins-linux-amd64-v1.8.0.tgz

## nerdctl 安装
wget https://github.com/containerd/nerdctl/releases/download/v2.1.6/nerdctl-2.1.6-linux-amd64.tar.gz && tar -zxvf nerdctl-2.1.6-linux-amd64.tar.gz && cp nerdctl /usr/local/bin/nerdctl

## buildkit 安装
wget https://github.com/moby/buildkit/releases/download/v0.25.1/buildkit-v0.25.1.linux-amd64.tar.gz && tar -zxvf buildkit-v0.25.1.linux-amd64.tar.gz && cp buildkitd /usr/local/bin/buildkitd && cp buildctl /usr/local/bin/buildctl
### buildkitd 命令启动
buildkitd --oci-worker=true --containerd-worker=true
### buildkit system注册服务
[Unit]
Description=BuildKit
Requires=buildkit.socket
After=buildkit.socket
Documentation=https://github.com/moby/buildkit

[Service]
Type=notify
ExecStart=/usr/local/bin/buildkitd --addr fd:// --oci-worker=auto --containerd-worker=true 

[Install]
WantedBy=multi-user.target


## containerd 安装
wget https://github.com/containerd/containerd/releases/download/v2.2.0-beta.2/containerd-static-2.2.0-beta.2-linux-amd64.tar.gz && tar -zxvf containerd-static-2.2.0-beta.2-linux-amd64.tar.gz -C /usr/local/bin --strip-components=1 && chmod +x /usr/local/bin/containerd  && curl https://raw.githubusercontent.com/containerd/containerd/main/containerd.service -o /etc/systemd/system/containerd.service && systemctl daemon-reload && systemctl enable containerd && systemctl start containerd

## kernel 配置
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.netfilter.nf_conntrack_max = 1048576 
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_timestamps = 1
fs.file-max = 1000000
net.ipv4.ip_local_port_range = 32768 65535
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 8096
vm.swappiness = 1 
vm.overcommit_memory = 1
fs.inotify.max_user_watches = 524288

## metrics-server tls 证书配置导致无法访问
    - --kubelet-insecure-tls  # 容器启动增加以上参数

## ubuntu 安装k8s组件
sudo apt-get update
### apt-transport-https 可以是一个虚拟包；如果是这样，你可以跳过这个包
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

### 如果 `/etc/apt/keyrings` 目录不存在，则应在 curl 命令之前创建它，请阅读下面的注释。
### sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg # allow unprivileged APT programs to read this keyring   

### 这会覆盖 /etc/apt/sources.list.d/kubernetes.list 中的所有现存配置
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo chmod 644 /etc/apt/sources.list.d/kubernetes.list   # 有助于让诸如 command-not-found 等工具正常工作

sudo apt-get update
sudo apt-get install -y kubelet kubeadm 


## calico

helm repo add projectcalico https://docs.tigera.io/calico/charts
helm show values projectcalico/tigera-operator --version ${官网获取版本} > /tmp/values.yaml
values.yaml
>   calicoNetwork:
    ipPools: # 增加ipPools配置
      - cidr: 10.244.0.0/16
        encapsulation: VXLAN
        natOutgoing: Enabled
helm install calico projectcalico/tigera-operator --namespace tigera-operator -f /tmp/values.yaml
https://docs.tigera.io/calico/latest/reference/installation/api#ippool
