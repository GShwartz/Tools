#!/bin/bash

# Set script env default args
INSTALL_HELM=false


show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  --install-helm      Automatically install Helm after setting up the Kubernetes cluster."
    echo "  --help              Display this help message."
    echo
    echo "Description:"
    echo "  This script sets up a Kubernetes cluster, initializes it with kubeadm,"
    echo "  configures kubectl for the user, and applies the Calico network plugin."
    echo "  Optionally, it can also install Helm based on user input or the --install-helm flag."
}

# Function to check if all nodes are ready with retry mechanism
are_all_nodes_ready() {
    local max_retries=5
    local retry_delay=10
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        local nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
        if [ -z "$nodes" ]; then
            echo "Attempt $attempt/$max_retries failed: Unable to get nodes status."
            attempt=$((attempt+1))
            sleep $retry_delay
        else
            local all_ready=true
            for status in $nodes; do
                if [ "$status" != "Ready" ]; then
                    all_ready=false
                    break
                fi
            done

            if [ "$all_ready" = true ]; then
                return 0
            fi

            # Start spinner in the background and get its process ID
            spin "Nodes not ready. Waiting..." &
            SPIN_PID=$!
            sleep $retry_delay
            kill $SPIN_PID 2>/dev/null
        fi
    done

    echo "Failed to get all nodes in Ready status after $max_retries attempts."
    return 1
}

# Function to check if all kube-system pods are ready with retry mechanism
are_all_system_pods_ready() {
    local max_retries=5
    local retry_delay=10
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        local pods=$(kubectl get pods --namespace kube-system --no-headers 2>/dev/null)
        if [ -z "$pods" ]; then
            echo "Attempt $attempt/$max_retries failed: Unable to get kube-system pods."
            attempt=$((attempt+1))
            sleep $retry_delay
        else
            local all_running=true
            echo "$pods" | awk '{split($2, a, "/"); if (a[1] != a[2] || $3 != "Running") exit 1}' || all_running=false

            if [ "$all_running" = true ]; then
                return 0
            fi

            # Start spinner in the background and get its process ID
            spin "Some kube-system pods are not running. Waiting..." &
            SPIN_PID=$!
            sleep $retry_delay
            kill $SPIN_PID 2>/dev/null
        fi
    done

    echo "Failed to get all kube-system pods in Running status after $max_retries attempts."
    return 1
}

# Function to display a spinning animation
spin() {
    spinner="/-\|"
    while :
    do
        for i in `seq 0 3`
        do
            echo -ne "\r${spinner:i:1} $1"
            sleep 0.1
        done
    done
}


# Process script arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --install-helm) INSTALL_HELM=true ;;
        --help) show_help; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; show_help; exit 1 ;;
    esac
    shift
done

echo "Disabling Swap..."
sudo swapoff -a

echo "Commenting swap line in /etc/fstab..."
sudo sed -i '/ swap / s/^/# /' /etc/fstab

echo "Running update..."
sudo apt update

echo "Installing dependencies..."
sudo apt install -y ufw apt-transport-https ca-certificates curl gnupg lsb-release

echo "Opening ports..."
sudo ufw allow 6443/tcp
sudo ufw allow 2379:2380/tcp
sudo ufw allow 10250/tcp
sudo ufw allow 10259/tcp
sudo ufw allow 10257/tcp

echo "Installing docker.io..."
sudo apt install -y docker.io

echo "Configuring docker daemon to use systemd..."
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

echo "Enabling docker..."
sudo systemctl enable docker

echo "Reloading docker daemon..."
sudo systemctl daemon-reload

echo "Restarting docker..."
sudo systemctl restart docker

# Clean up existing Kubernetes repository entries
echo "Cleaning up existing Kubernetes repository entries..."
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/sources.list.d/google-cloud-sdk.list
sudo rm -f /etc/apt/sources.list.d/kubernetes.list.save
sudo sed -i '/kubernetes/d' /etc/apt/sources.list
sudo sed -i '/packages.cloud.google.com/d' /etc/apt/sources.list

echo "Updating signing key..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "Adding Kubernetes apt repository..."
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

echo "Running apt-get update..."
sudo apt-get update

echo "Installing kubelet, kubeadm, kubectl..."
sudo apt-get install -y kubelet kubeadm kubectl

echo "Locking current version of kubelet, kubeadm, kubectl..."
sudo apt-mark hold kubelet kubeadm kubectl

echo "Enabling and starting kubelet service..."
sudo systemctl enable --now kubelet

# Proper Init
echo "Initializing Kubernetes cluster with kubeadm..."
sudo kubeadm init --apiserver-advertise-address=$(hostname -I | awk '{print $1}') --pod-network-cidr=192.168.100.0/24

echo "Setting up local kubeconfig..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Applying Calico network plugin
printf '=%.0s' {1..140}
echo
echo "Applying Calico network plugin..."
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.25.0/manifests/calico.yaml

# Main loop to check readiness with spinning animation
while true; do
    if are_all_nodes_ready && are_all_system_pods_ready; then
		# Kill the spinner process
        kill $SPIN_PID 2>/dev/null  
		
		echo ""
        echo "All nodes and system pods are ready."
        echo ""
        
		break
    else
        # Start spinner in the background and get its process ID
        spin "Waiting for nodes and system pods to become ready..." &
        SPIN_PID=$!
		
        sleep 5
		
		# Kill the spinner process to restart it
        kill $SPIN_PID 2>/dev/null  
    fi
done

printf '=%.0s' {1..140}
echo

kubectl get pods -n kube-system
kubectl get nodes

if [ "$INSTALL_HELM" = true ]; then
    printf '=%.0s' {1..140}
    echo
    echo "Installing Helm..."
    
    # Download and install Helm
    curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

    # Verify Helm installation
    helm version
	echo
    echo "Helm installation completed."
	
else
    # Ask the user if they want to install Helm
	printf '=%.0s' {1..140}
    echo
    read -p "Do you want to install Helm? [y/N]: " install_helm
    
    if [[ $install_helm =~ ^[Yy]$ ]]; then
        printf '=%.0s' {1..140}
        echo
        echo "Installing Helm..."
        
        # Download and install Helm
        curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

        # Verify Helm installation
        helm version

        printf '=%.0s' {1..140}
        echo
        echo "Helm installation completed."
    else
        echo "Skipping Helm installation."
    fi
fi

printf '=%.0s' {1..140}
echo
echo "Use the following command to create new joining commands:"
echo "kubeadm token create --print-join-command"
echo ""
