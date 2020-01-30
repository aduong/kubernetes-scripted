#!/usr/bin/env bash

set -o errexit -o nounset

BRANCH="${BRANCH:-master}"
echo "deb http://download.opensuse.org/repositories/home:/katacontainers:/releases:/$(arch):/${BRANCH}/xUbuntu_$(lsb_release -rs)/ /" | sudo tee /etc/apt/sources.list.d/kata-containers.list
curl -sL "https://download.opensuse.org/repositories/home:/katacontainers:/releases:/$(arch):/${BRANCH}/xUbuntu_$(lsb_release -rs)/Release.key" | sudo apt-key add -

sudo apt-get update
sudo apt-get install -y socat conntrack ipset kata-runtime kata-proxy kata-shim qemu-kvm

wget -q --https-only --timestamping 'https://dl.k8s.io/v1.17.0/kubernetes-server-linux-amd64.tar.gz'
sha512sum -c <(echo '28b2703c95894ab0565e372517c4a4b2c33d1be3d778fae384a6ab52c06cea7dd7ec80060dbdba17c8ab23bbedcde751cccee7657eba254f7d322cf7c4afc701 kubernetes-server-linux-amd64.tar.gz')
tar -xvf kubernetes-server-linux-amd64.tar.gz
(
  cd kubernetes/server/bin/
  chmod +x kubectl kube-proxy kubelet
  sudo mv kubectl kube-proxy kubelet /usr/local/bin/
  cd ~
  rm -rf kubernetes/
)

wget -q --https-only --timestamping \
  https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.17.0/crictl-v1.17.0-linux-amd64.tar.gz \
  https://github.com/opencontainers/runc/releases/download/v1.0.0-rc10/runc.amd64 \
  https://github.com/containernetworking/plugins/releases/download/v0.8.5/cni-plugins-linux-amd64-v0.8.5.tgz \
  https://github.com/containerd/containerd/releases/download/v1.3.2/containerd-1.3.2.linux-amd64.tar.gz

sha512sum -c << EOF
e258f4607a89b8d44c700036e636dd42cc3e2ed27a3bb13beef736f80f64f10b7974c01259a66131d3f7b44ed0c61b1ca0ea91597c416a9c095c432de5112d44  crictl-v1.17.0-linux-amd64.tar.gz
040f438c99a65de3896793f1ada6038095607d965b2187d9c83cabd1c33a4a6c292ce34ba6982ebe2921b308140fa474bc995ac75c279df2f6deb440167539d4  runc.amd64
497be012e1e3c605c467752ee5729de35d88afd7a0bfa237a6cf979413d65bda34865a8dd952ca1d32581bb5669d567c2c7f2d23dd92db3ba9101204583a8482  cni-plugins-linux-amd64-v0.8.5.tgz
482c03b145b13f47cfc82225455097f5e8a9db4e882aba4e675bd44df37245e0eeec9d832f3be2f0cf3cc934ec0c4a3c828ae9c0d972d2066557b75c1c3bd072  containerd-1.3.2.linux-amd64.tar.gz
EOF

sudo mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes

# install runc & crictl

sudo mv runc.amd64 runc
tar -xvf crictl-v1.17.0-linux-amd64.tar.gz
chmod +x crictl runc
sudo mv crictl runc /usr/local/bin/

# configure CNI networking
sudo tar -xvf cni-plugins-linux-amd64-v0.8.5.tgz -C /opt/cni/bin/

pod_cidr=$(curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/attributes/pod-cidr)
sudo tee /etc/cni/net.d/10-bridge.conf << EOF
{
    "cniVersion": "0.3.1",
    "name": "bridge",
    "type": "bridge",
    "bridge": "cnio0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
        "type": "host-local",
        "ranges": [
          [{"subnet": "${pod_cidr}"}]
        ],
        "routes": [{"dst": "0.0.0.0/0"}]
    }
}
EOF

sudo tee /etc/cni/net.d/99-loopback.conf << EOF
{
    "cniVersion": "0.3.1",
    "name": "lo",
    "type": "loopback"
}
EOF

# configure containerd
mkdir containerd
tar -xvf containerd-1.3.2.linux-amd64.tar.gz -C containerd
sudo mv containerd/bin/* /bin/

sudo mkdir -p /etc/containerd/
sudo tee /etc/containerd/config.toml << EOF
[plugins]
  [plugins.cri.containerd]
    default_runtime_name = "runc"
  [plugins.cri.containerd.runtimes]
    [plugins.cri.containerd.runtimes.runc]
      runtime_type = "io.containerd.runc.v1"
      [plugins.cri.containerd.runtimes.runc.options]
         NoPivotRoot = false
         NoNewKeyring = false
         ShimCgroup = ""
         IoUid = 0
         IoGid = 0
         BinaryName = "runc"
         Root = ""
         CriuPath = ""
         SystemdCgroup = false
    [plugins.cri.containerd.runtimes.kata]
      runtime_type = "io.containerd.kata.v2"
EOF

sudo tee /etc/systemd/system/containerd.service << EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=/sbin/modprobe overlay
ExecStart=/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

# configure kubelet

sudo mv "${HOSTNAME}-key.pem" "${HOSTNAME}.pem" /var/lib/kubelet/
sudo mv "${HOSTNAME}.kubeconfig" /var/lib/kubelet/kubeconfig
sudo mv ca.pem /var/lib/kubernetes/

sudo tee /var/lib/kubelet/kubelet-config.yaml << EOF
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.32.0.10"
podCIDR: "${pod_cidr}"
resolvConf: "/run/systemd/resolve/resolv.conf"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/${HOSTNAME}.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/${HOSTNAME}-key.pem"
EOF

sudo tee /etc/systemd/system/kubelet.service << EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --container-runtime=remote \\
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\
  --image-pull-progress-deadline=2m \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --network-plugin=cni \\
  --register-node=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# configure kubernetes proxy

sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig

sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml << EOF
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.200.0.0/16"
EOF

sudo tee /etc/systemd/system/kube-proxy.service << EOF
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# start things up

sudo systemctl daemon-reload
sudo systemctl enable containerd kubelet kube-proxy
sudo systemctl start containerd kubelet kube-proxy

echo 'done'
