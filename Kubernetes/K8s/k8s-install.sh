#!/bin/bash


# Function to check if all nodes are ready
are_all_nodes_ready() {
    local nodes=$(kubectl get nodes --no-headers | awk '{print $2}')

    for status in $nodes; do
        if [ "$status" != "Ready" ]; then
            return 1
        fi
    done

    return 0
}

# Function to check if all kube-system pods are ready
are_all_system_pods_ready() {
    # Get the status of each pod in the kube-system namespace
    local pods=$(kubectl get pods --namespace kube-system --no-headers)

    # Check if all pods are in 'Running' status and containers are ready
    echo "$pods" | awk '{split($2, a, "/"); if (a[1] != a[2] || $3 != "Running") exit 1}'
    return $?
}

sudo apt update
sudo apt upgrade -y
sudo swapoff -a
sudo sed -i '$ d' /etc/fstab

sudo tee /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

sudo apt install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt install -y containerd.io
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/kubernetes-xenial.gpg
sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"

sudo apt update
sudo apt install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo kubeadm init

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml

# Main loop to check readiness
while true; do
    if are_all_nodes_ready && are_all_system_pods_ready; then
        echo "All nodes and system pods are ready."
        break
    else
        echo "Waiting for nodes and system pods to become ready..."
    fi
    sleep 5
done

kubectl get pods -n kube-system
kubectl get nodes