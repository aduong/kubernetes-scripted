#!/usr/bin/env bash

set -o errexit -o nounset

# install etcd
wget -q --show-progress --https-only --timestamping \
  'https://github.com/etcd-io/etcd/releases/download/v3.4.3/etcd-v3.4.3-linux-amd64.tar.gz'

sha256sum -c <(echo '6c642b723a86941b99753dff6c00b26d3b033209b15ee33325dc8e7f4cd68f07  etcd-v3.4.3-linux-amd64.tar.gz')

tar -xvf etcd-v3.4.3-linux-amd64.tar.gz
sudo mv etcd-v3.4.3-linux-amd64/etcd* /usr/local/bin/

# configure etcd
sudo mkdir -p /etc/etcd /var/lib/etcd
sudo cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/

internal_ip=$(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)
etcd_name=$(hostname -s)

cat << EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name ${etcd_name} \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${internal_ip}:2380 \\
  --listen-peer-urls https://${internal_ip}:2380 \\
  --listen-client-urls https://${internal_ip}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${internal_ip}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster controller-0=https://10.240.0.10:2380,controller-1=https://10.240.0.11:2380,controller-2=https://10.240.0.12:2380 \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd
echo 'done'
