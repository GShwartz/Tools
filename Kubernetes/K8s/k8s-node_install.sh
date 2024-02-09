#!/bin/bash

# Updating and upgrading system packages
echo "Updating system packages..."
sudo apt update
sudo apt upgrade -y

# Disabling swap - required for Kubernetes
echo "Disabling swap..."
sudo swapoff -a

# Removing swap entry from /etc/fstab to make the change permanent
echo "Updating /etc/fstab to disable swap permanently..."
sudo sed -i '$ d' /etc/fstab

# Setting up required kernel modules for containerd
echo "Configuring kernel modules for containerd..."
sudo tee /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF

# Loading the overlay and br_netfilter modules
echo "Loading kernel modules..."
sudo modprobe overlay
sudo modprobe br_netfilter

# Configuring sysctl parameters required by Kubernetes
echo "Configuring sysctl parameters for Kubernetes..."
sudo tee /etc/sysctl.d/kubernetes.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

# Applying sysctl settings
echo "Applying sysctl settings..."
sudo sysctl --system

# Installing prerequisites for containerd
echo "Installing prerequisites for containerd..."
sudo apt install -y curl gnupg2 software-properties-common apt-transport-https ca-certificates

# Adding Docker's official GPG key
echo "Adding Docker's GPG key..."
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/docker.gpg

# Adding Docker repository
echo "Adding Docker repository..."
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

# Installing containerd
echo "Installing containerd..."
sudo apt install -y containerd.io

# Configuring containerd and restarting the service
echo "Configuring containerd..."
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml
echo "Restarting containerd service..."
sudo systemctl restart containerd
sudo systemctl enable containerd

# Adding Kubernetes GPG key
echo "Adding Kubernetes GPG key..."
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmour -o /etc/apt/trusted.gpg.d/kubernetes-xenial.gpg

# Adding Kubernetes repository
echo "Adding Kubernetes repository..."
sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"

# Updating package listings
echo "Updating package listings..."
sudo apt update

# Installing Kubernetes components: kubelet, kubeadm, and kubectl
echo "Installing Kubernetes components (kubelet, kubeadm, kubectl)..."
sudo apt install -y kubelet kubeadm kubectl

# Preventing these packages from being automatically updated
echo "Marking Kubernetes packages to hold to prevent automatic updates..."
sudo apt-mark hold kubelet kubeadm kubectl

echo "Kubernetes installation complete."
echo "Use the following command to join this node to a cluster:"
echo "kubeadm join <master-ip>:<master-port usually 6443> --token <token> --discovery-token-ca-cert-hash <discovery token hash>"
echo ""