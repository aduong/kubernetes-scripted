#!/usr/bin/env bash

set -o errexit -o nounset

compute_region=$(gcloud config get-value compute/region)

# do networking stuff
gcloud compute networks create kubernetes-the-hard-way \
  --subnet-mode custom
gcloud compute networks subnets create kubernetes \
  --network kubernetes-the-hard-way \
  --range 10.240.0.0/24
gcloud compute firewall-rules create kubernetes-the-hard-way-allow-internal \
  --allow tcp,udp,icmp \
  --network kubernetes-the-hard-way \
  --source-ranges 10.240.0.0/24,10.200.0.0/16
gcloud compute firewall-rules create kubernetes-the-hard-way-allow-external \
  --allow tcp:22,tcp:6443,icmp \
  --network kubernetes-the-hard-way \
  --source-ranges 0.0.0.0/0
gcloud compute addresses create kubernetes-the-hard-way \
  --region "$compute_region"

kubernetes_public_address=$(
  gcloud compute addresses describe kubernetes-the-hard-way \
    --region "$compute_region" \
    --format 'value(address)'
)

gcloud compute routers create nat-router-kubernetes --network kubernetes-the-hard-way
gcloud compute routers nats create nat-kubernetes \
  --router nat-router-kubernetes \
  --auto-allocate-nat-external-ips \
  --nat-all-subnet-ip-ranges

# provision machines

## create controller machines
for i in 0 1 2; do
  gcloud compute instances create controller-${i} \
    --async \
    --boot-disk-size 200GB \
    --can-ip-forward \
    --image-family ubuntu-1804-lts \
    --image-project ubuntu-os-cloud \
    --machine-type n1-standard-1 \
    --no-address \
    --private-network-ip 10.240.0.1${i} \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --subnet kubernetes \
    --tags kubernetes-the-hard-way,controller
done

## create disks for vmx
gcloud compute disks create vmx-disk \
  --image-project ubuntu-os-cloud \
  --image-family ubuntu-1804-lts \
  --zone "$(gcloud config get-value compute/zone)"

gcloud compute images create ubuntu-1804-lts-vmx \
  --source-disk vmx-disk \
  --source-disk-zone "$(gcloud config get-value compute/zone)" \
  --licenses "https://compute.googleapis.com/compute/v1/projects/vm-options/global/licenses/enable-vmx"

gcloud -q compute disks delete vmx-disk

## create worker machines
for i in 0 1 2; do
  gcloud compute instances create worker-${i} \
    --async \
    --boot-disk-size 200GB \
    --can-ip-forward \
    --image ubuntu-1804-lts-vmx \
    --machine-type n1-standard-1 \
    --metadata pod-cidr=10.200.${i}.0/24 \
    --no-address \
    --private-network-ip 10.240.0.2${i} \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --subnet kubernetes \
    --tags kubernetes-the-hard-way,worker
done

# certificates

## CA key/cert

cat > tls/ca-config.json << EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat > tls/ca-csr.json << EOF
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert -initca tls/ca-csr.json | cfssljson -bare tls/ca

## admin client cert

cat > tls/admin-csr.json << EOF
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:masters",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=tls/ca.pem \
  -ca-key=tls/ca-key.pem \
  -config=tls/ca-config.json \
  -profile=kubernetes \
  tls/admin-csr.json | cfssljson -bare tls/admin

## kubelet client certs

for instance in worker-0 worker-1 worker-2; do
  cat > tls/${instance}-csr.json << EOF
{
  "CN": "system:node:${instance}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

  internal_ip=$(gcloud compute instances describe ${instance} --format 'value(networkInterfaces[0].networkIP)')

  cfssl gencert \
    -ca=tls/ca.pem \
    -ca-key=tls/ca-key.pem \
    -config=tls/ca-config.json \
    -hostname="${instance},${internal_ip}" \
    -profile=kubernetes \
    tls/${instance}-csr.json | cfssljson -bare tls/${instance}
done

## controller manager client certificate

cat > tls/kube-controller-manager-csr.json << EOF
{
  "CN": "system:kube-controller-manager",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-controller-manager",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=tls/ca.pem \
  -ca-key=tls/ca-key.pem \
  -config=tls/ca-config.json \
  -profile=kubernetes \
  tls/kube-controller-manager-csr.json | cfssljson -bare tls/kube-controller-manager

## kube proxy client certificate

cat > tls/kube-proxy-csr.json << EOF
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:node-proxier",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=tls/ca.pem \
  -ca-key=tls/ca-key.pem \
  -config=tls/ca-config.json \
  -profile=kubernetes \
  tls/kube-proxy-csr.json | cfssljson -bare tls/kube-proxy

## scheduler client certificate

cat > tls/kube-scheduler-csr.json << EOF
{
  "CN": "system:kube-scheduler",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-scheduler",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=tls/ca.pem \
  -ca-key=tls/ca-key.pem \
  -config=tls/ca-config.json \
  -profile=kubernetes \
  tls/kube-scheduler-csr.json | cfssljson -bare tls/kube-scheduler

## API server certificate

kubernetes_hostnames=kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.svc.cluster.local

cat > tls/kubernetes-csr.json << EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=tls/ca.pem \
  -ca-key=tls/ca-key.pem \
  -config=tls/ca-config.json \
  -hostname="10.32.0.1,10.240.0.10,10.240.0.11,10.240.0.12,${kubernetes_public_address},127.0.0.1,${kubernetes_hostnames}" \
  -profile=kubernetes \
  tls/kubernetes-csr.json | cfssljson -bare tls/kubernetes

## service account key pair
cat > tls/service-account-csr.json << EOF
{
  "CN": "service-accounts",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=tls/ca.pem \
  -ca-key=tls/ca-key.pem \
  -config=tls/ca-config.json \
  -profile=kubernetes \
  tls/service-account-csr.json | cfssljson -bare tls/service-account

## wait for instances to become accessible
for instance_type in worker controller; do
  for i in 0 1 2; do
    until gcloud compute ssh $instance_type-$i --command=exit; do
      date
      echo "waiting for $instance_type-$i to become accessible"
      sleep 2
    done
  done
done

## copy worker client key pair
for instance in worker-0 worker-1 worker-2; do
  gcloud compute scp \
    tls/ca.pem \
    tls/${instance}-key.pem \
    tls/${instance}.pem \
    ${instance}:~/
done

## copy controller key pairs and certificates
for instance in controller-0 controller-1 controller-2; do
  gcloud compute scp \
    tls/ca.pem \
    tls/ca-key.pem \
    tls/kubernetes-key.pem \
    tls/kubernetes.pem \
    tls/service-account-key.pem \
    tls/service-account.pem \
    ${instance}:~/
done

# kubernetes configuration files for authentication

mkdir -p configs

## kubelet kubernetes configuration file

for instance in worker-0 worker-1 worker-2; do
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=tls/ca.pem \
    --embed-certs=true \
    --server="https://${kubernetes_public_address}:6443" \
    --kubeconfig=configs/${instance}.kubeconfig

  kubectl config set-credentials system:node:${instance} \
    --client-certificate=tls/${instance}.pem \
    --client-key=tls/${instance}-key.pem \
    --embed-certs=true \
    --kubeconfig=configs/${instance}.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:node:${instance} \
    --kubeconfig=configs/${instance}.kubeconfig

  kubectl config use-context default \
    --kubeconfig=configs/${instance}.kubeconfig
done

## kube-proxy kubernetes configuration file

kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=tls/ca.pem \
  --embed-certs=true \
  --server="https://${kubernetes_public_address}:6443" \
  --kubeconfig=configs/kube-proxy.kubeconfig

kubectl config set-credentials system:kube-proxy \
  --client-certificate=tls/kube-proxy.pem \
  --client-key=tls/kube-proxy-key.pem \
  --embed-certs=true \
  --kubeconfig=configs/kube-proxy.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hard-way \
  --user=system:kube-proxy \
  --kubeconfig=configs/kube-proxy.kubeconfig

kubectl config use-context default \
  --kubeconfig=configs/kube-proxy.kubeconfig

## kube-controller-manager kubernetes configuration file

kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=tls/ca.pem \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=configs/kube-controller-manager.kubeconfig

kubectl config set-credentials system:kube-controller-manager \
  --client-certificate=tls/kube-controller-manager.pem \
  --client-key=tls/kube-controller-manager-key.pem \
  --embed-certs=true \
  --kubeconfig=configs/kube-controller-manager.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hard-way \
  --user=system:kube-controller-manager \
  --kubeconfig=configs/kube-controller-manager.kubeconfig

kubectl config use-context default \
  --kubeconfig=configs/kube-controller-manager.kubeconfig

## kube-scheduler kubernetes configuration file

kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=tls/ca.pem \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=configs/kube-scheduler.kubeconfig

kubectl config set-credentials system:kube-scheduler \
  --client-certificate=tls/kube-scheduler.pem \
  --client-key=tls/kube-scheduler-key.pem \
  --embed-certs=true \
  --kubeconfig=configs/kube-scheduler.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hard-way \
  --user=system:kube-scheduler \
  --kubeconfig=configs/kube-scheduler.kubeconfig

kubectl config use-context default \
  --kubeconfig=configs/kube-scheduler.kubeconfig

## admin kubernetes configuration file

kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=tls/ca.pem \
  --embed-certs=true \
  --server=https://127.0.0.1:6443 \
  --kubeconfig=configs/admin.kubeconfig

kubectl config set-credentials admin \
  --client-certificate=tls/admin.pem \
  --client-key=tls/admin-key.pem \
  --embed-certs=true \
  --kubeconfig=configs/admin.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hard-way \
  --user=admin \
  --kubeconfig=configs/admin.kubeconfig

kubectl config use-context default \
  --kubeconfig=configs/admin.kubeconfig

## distribute worker kubernetes configurations (kubelet & kube-proxy)
for instance in worker-0 worker-1 worker-2; do
  gcloud compute scp \
    configs/${instance}.kubeconfig \
    configs/kube-proxy.kubeconfig \
    ${instance}:~/
done

## distribute controller kubernetes configurations (admin, kube-controller, kube-scheduler)
for instance in controller-0 controller-1 controller-2; do
  gcloud compute scp \
    configs/admin.kubeconfig \
    configs/kube-controller-manager.kubeconfig \
    configs/kube-scheduler.kubeconfig \
    ${instance}:~/
done

# data encryption config & key
cat > configs/encryption-config.yaml << EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: $(head -c 32 /dev/urandom | base64)
      - identity: {}
EOF

for instance in controller-0 controller-1 controller-2; do
  gcloud compute scp \
    configs/encryption-config.yaml \
    ${instance}:~/
done

# setup etcd

for i in 0 1 2; do
  gcloud compute scp setup-etcd.sh controller-${i}:~/
  gcloud compute ssh controller-${i} --command='./setup-etcd.sh' -- -n > controller-${i}-setup-etcd.log 2>&1 &
done

wait

# setup kubernetes control plane

for i in 0 1 2; do
  gcloud compute scp setup-kubernetes-control-plane.sh controller-${i}:~/
  gcloud compute ssh controller-${i} --command='./setup-kubernetes-control-plane.sh' -- -n > controller-${i}-setup-kubernetes-control-plane.log 2>&1 &
done

wait

# authorize kubelet to the kubernetes API

gcloud compute scp authorize-kubelet.sh controller-0:~/
gcloud compute ssh controller-0 --command='./authorize-kubelet.sh'

# add loadbalancer for Kubernetes frontend

gcloud compute http-health-checks create kubernetes \
  --description "Kubernetes Health Check" \
  --host "kubernetes.default.svc.cluster.local" \
  --request-path "/healthz"

gcloud compute firewall-rules create kubernetes-the-hard-way-allow-health-check \
  --network kubernetes-the-hard-way \
  --source-ranges 209.85.152.0/22,209.85.204.0/22,35.191.0.0/16 \
  --allow tcp

gcloud compute target-pools create kubernetes-target-pool \
  --http-health-check kubernetes

gcloud compute target-pools add-instances kubernetes-target-pool \
  --instances controller-0,controller-1,controller-2

gcloud compute forwarding-rules create kubernetes-forwarding-rule \
  --address "${kubernetes_public_address}" \
  --ports 6443 \
  --region "${compute_region}" \
  --target-pool kubernetes-target-pool

# setup worker nodes

for i in 0 1 2; do
  gcloud compute scp setup-worker.sh worker-${i}:~/
  gcloud compute ssh worker-${i} --command='./setup-worker.sh' -- -n > worker-${i}-setup.log 2>&1 &
done

wait

# configure kubectl locally

kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=tls/ca.pem \
  --embed-certs=true \
  --server="https://${kubernetes_public_address}:6443"

kubectl config set-credentials admin \
  --client-certificate=tls/admin.pem \
  --client-key=tls/admin-key.pem

kubectl config set-context kubernetes-the-hard-way \
  --cluster=kubernetes-the-hard-way \
  --user=admin

kubectl config use-context kubernetes-the-hard-way

# route pod IP addresses to node

for i in 0 1 2; do
  gcloud compute routes create kubernetes-route-10-200-${i}-0-24 \
    --network kubernetes-the-hard-way \
    --next-hop-address 10.240.0.2${i} \
    --destination-range 10.200.${i}.0/24
done

# setup kata

kubectl apply --context kubernetes-the-hard-way -f kata-runtime-class.yaml

# setup CoreDNS

kubectl apply --context kubernetes-the-hard-way -f coredns.yaml
