#!/bin/bash

# Install MicroK8s
sudo snap install microk8s --classic

# Wait for MicroK8s to be running
while true; do
    if sudo microk8s status | grep -q "microk8s is running"; then
        echo "MicroK8s is running."
        break
    else
        echo "Waiting for MicroK8s to start..."
        sleep 5
    fi
done

# Display MicroK8s status
sudo microk8s status

# Enable ingress controller
sudo microk8s enable ingress

# Get all resources in kube-system namespace
sudo microk8s kubectl get all -n kube-system

# Create .kube directory and retrieve config
mkdir -p ~/.kube
sudo microk8s kubectl config view --raw > ~/.kube/config

sudo mkdir -p /var/jenkins_home
sudo chmod 777 /var/jenkins_home

sudo microk8s add-node

#microk8s kubectl label nodes node-1 nodename=node-1
