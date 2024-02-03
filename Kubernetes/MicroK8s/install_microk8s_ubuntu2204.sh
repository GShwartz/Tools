#!/bin/bash

# Define the kube-apiserver configuration file path
API_SERVER_CONFIG="/var/snap/microk8s/current/args/kube-apiserver"

# Function to validate the port range input
validate_port_range() {
    if [[ $1 =~ ^[0-9]+-[0-9]+$ ]]; then
        IFS='-' read -ra PORTS <<< "$1"
        if [ "${PORTS[0]}" -ge 1 ] && [ "${PORTS[1]}" -le 65535 ] && [ "${PORTS[0]}" -le "${PORTS[1]}" ]; then
            return 0
        fi
    fi
    return 1
}

# Function to prompt for the NodePort range
prompt_for_port_range() {
    for i in {1..3}; do
        echo "Attempt $i: Please enter the desired NodePort range (e.g., 8000-32767):"
        read -r NODE_PORT_RANGE_INPUT

        if validate_port_range "$NODE_PORT_RANGE_INPUT"; then
            NODE_PORT_RANGE="--service-node-port-range=$NODE_PORT_RANGE_INPUT"
            return 0
        else
            echo "Invalid NodePort range. Please ensure it's in the format 'minPort-maxPort' and within 1-65535."
        fi
    done
    return 1
}

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

# Prompt the user to enter the desired NodePort range and validate input
if ! prompt_for_port_range; then
    echo "Failed to enter a valid NodePort range after 3 attempts. Exiting."
    exit 1
fi

# Check if the NodePort range setting already exists
if sudo grep -q "service-node-port-range" "$API_SERVER_CONFIG"; then
    echo "Updating the NodePort range in the kube-apiserver configuration..."
    sudo sed -i "/service-node-port-range/c\\$NODE_PORT_RANGE" "$API_SERVER_CONFIG"
else
    echo "Adding the NodePort range to the kube-apiserver configuration..."
    echo "$NODE_PORT_RANGE" | sudo tee -a "$API_SERVER_CONFIG" > /dev/null
fi

# Restart MicroK8s to apply the changes
echo "Restarting MicroK8s..."
sudo microk8s stop
sudo microk8s start

echo "NodePort range updated successfully."
echo ""
echo "[=======================================================================================================================]"

sudo microk8s add-node

echo "[=======================================================================================================================]"
echo "Remember the following commands:"
echo "alias kubectl='sudo microk8s kubectl'"
echo "kubectl get nodes"
echo "sudo microk8s kubectl label nodes <node-name> nodename=<node-hostname>"
echo ""
echo ""