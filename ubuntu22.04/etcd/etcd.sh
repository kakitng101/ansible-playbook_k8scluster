#!/bin/bash

export HOST0=$host1
export HOST1=$host2
export HOST2=$host3


export NAME0="etcd1"
export NAME1="etcd2"
export NAME2="etcd3"

mkdir -p /tmp/ubuntu/etcd/${HOST0}/ /tmp/ubuntu/etcd/${HOST1}/ /tmp/ubuntu/etcd/${HOST2}/

HOSTS=(${HOST0} ${HOST1} ${HOST2})
NAMES=(${NAME0} ${NAME1} ${NAME2})


for i in "${!HOSTS[@]}"; do
HOST=${HOSTS[$i]}
NAME=${NAMES[$i]}
ETCD_CONF="/etc/etcd/pki/etcd"
cat << EOF > /tmp/ubuntu/etcd/${HOST}/kubeadmcfg.yaml
---
apiVersion: "kubeadm.k8s.io/v1beta4"
kind: InitConfiguration
nodeRegistration:
    name: ${NAME}
localAPIEndpoint:
    advertiseAddress: ${HOST}
---
apiVersion: "kubeadm.k8s.io/v1beta4"
kind: ClusterConfiguration
etcd:
    local:
        serverCertSANs:
        - "${HOST}"
        peerCertSANs:
        - "${HOST}"
        extraArgs:
        - name: initial-cluster
          value: ${NAMES[0]}=https://${HOSTS[0]}:2380,${NAMES[1]}=https://${HOSTS[1]}:2380,${NAMES[2]}=https://${HOSTS[2]}:2380
        - name: initial-cluster-state
          value: new
        - name: name
          value: ${NAME}
        - name: listen-peer-urls
          value: https://${HOST}:2380
        - name: listen-client-urls
          value: https://${HOST}:2379
        - name: advertise-client-urls
          value: https://${HOST}:2379
        - name: initial-advertise-peer-urls
          value: https://${HOST}:2380
EOF
kubeadm init phase certs etcd-ca
kubeadm init phase certs etcd-server --config=/tmp/ubuntu/etcd/${HOST}/kubeadmcfg.yaml
kubeadm init phase certs etcd-peer --config=/tmp/ubuntu/etcd/${HOST}/kubeadmcfg.yaml
kubeadm init phase certs etcd-healthcheck-client --config=/tmp/ubuntu/etcd/${HOST}/kubeadmcfg.yaml
kubeadm init phase certs apiserver-etcd-client --config=/tmp/ubuntu/etcd/${HOST}/kubeadmcfg.yaml
cp -R /etc/kubernetes/pki /tmp/ubuntu/etcd/${HOST}/
find /etc/kubernetes/pki -not -name ca.crt -not -name ca.key -type f -delete
cat << EOF > /tmp/ubuntu/etcd/${HOST}/etcd.service
[Unit]
Description=Etcd Server
Documentation=https://github.com/coreos/etcd
After=network.target

[Service]
Type=notify
OOMScoreAdjust=-999
LimitNOFILE=65536
User=root
Group=root

ExecStart=/usr/local/bin/etcd \
  --name $NAME \
  --data-dir /var/lib/etcd \
  --max-snapshots 10 \
  --max-wals 10 \
  --listen-peer-urls https://${HOST}:2380 \
  --listen-client-urls https://${HOST}:2379,https://127.0.0.1:2379 \
  --advertise-client-urls https://${HOST}:2379 \
  --initial-advertise-peer-urls https://${HOST}:2380 \
  --initial-cluster-token etcd-cluster \
  --initial-cluster "etcd1=https://${HOSTS[0]}:2380,etcd2=https://${HOSTS[1]}:2380,etcd3=https://${HOSTS[2]}:2380" \
  --peer-cert-file=${ETCD_CONF}/peer.crt \
  --peer-key-file=${ETCD_CONF}/peer.key \
  --peer-trusted-ca-file=${ETCD_CONF}/ca.crt \
  --peer-client-cert-auth=true \
  --cert-file=${ETCD_CONF}/server.crt \
  --key-file=${ETCD_CONF}/server.key \
  --trusted-ca-file=${ETCD_CONF}/ca.crt \
  --client-cert-auth=true \
  --initial-cluster-state new

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
done
