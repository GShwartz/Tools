#!/bin/bash

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

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --install-helm) INSTALL_HELM=true ;;
        --help) show_help; exit 0 ;;
        *) echo "Unknown parameter passed: $1"; show_help; exit 1 ;;
    esac
    shift
done

disable_swap() {
	sudo swapoff -a

	echo "Commenting swap line in /etc/fstab..."
	sudo sed -i '/ swap / s/^/# /' /etc/fstab
}

install_dependencies() {
	sudo apt install -y ufw apt-transport-https ca-certificates curl gnupg lsb-release socat conntrack

}

open_ports() {
	sudo ufw allow 6443/tcp   # Kubernetes API server
	sudo ufw allow 2379:2380/tcp  # etcd server client API
	sudo ufw allow 10250/tcp  # Kubelet API
	sudo ufw allow 10259/tcp  # kube-scheduler
	sudo ufw allow 10257/tcp  # kube-controller-manager
}

config_sysctl_params() {
	echo "Config_Sysctl_Params: Loading necessary kernel modules..."

	sudo modprobe overlay
	sudo modprobe br_netfilter
	
	sudo tee /etc/sysctl.d/kubernetes.conf<<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
	
	echo "Config_Sysctl_Params: Applying sysctl params..."
	sudo sysctl --system
}

install_containerd() {
	sudo apt install -y containerd

	echo "Configuring containerd..."
	sudo mkdir -p /etc/containerd
	sudo containerd config default | sudo tee /etc/containerd/config.toml

	echo "Setting cgroup driver to systemd in containerd config..."
	sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

	echo "Restarting containerd..."
	sudo systemctl restart containerd
	sudo systemctl enable containerd
}

pre_k8s_cleanup() {
	sudo rm -f /etc/apt/sources.list.d/kubernetes.list
	sudo rm -f /etc/apt/sources.list.d/google-cloud-sdk.list
	sudo sed -i '/kubernetes/d' /etc/apt/sources.list
	sudo sed -i '/packages.cloud.google.com/d' /etc/apt/sources.list
}

update_signing_key() {
	sudo mkdir -p /etc/apt/keyrings
	curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
}

add_k8s_repo() {
	echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
}

install_k8s() {
	sudo apt-get install -y kubelet kubeadm kubectl

	echo "Install_K8s: Locking current version of kubelet, kubeadm, kubectl..."
	sudo apt-mark hold kubelet kubeadm kubectl

	echo "Install_K8s: Enabling and starting kubelet service..."
	sudo systemctl enable --now kubelet
}

config_k8s() {
	sudo mkdir -p /etc/systemd/system/kubelet.service.d
	cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/20-containerd.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF

	sudo mkdir -p /var/lib/kubelet
	cat <<EOF | sudo tee /var/lib/kubelet/config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd
EOF

}

k8s_reload_restart() {
	sudo systemctl daemon-reload
	sudo systemctl restart kubelet
}

init_k8s_cluster() {
	sudo kubeadm init --apiserver-advertise-address=$(hostname -I | awk '{print $1}') \
	--pod-network-cidr=192.168.0.0/16
}

setup_local_k8s() {
	mkdir -p $HOME/.kube
	sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	sudo chown $(id -u):$(id -g) $HOME/.kube/config
}

monitor() {
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
}

check_helm() {
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
}


main() {
	echo "Disabling Swap..."
	disable_swap

	echo "Running update..."
	sudo apt update

	printf '=%.0s' {1..140}
	echo
	echo "Installing dependencies..."
	install_dependencies

	printf '=%.0s' {1..140}
	echo
	echo "Opening necessary ports..."
	open_ports

	printf '=%.0s' {1..140}
	echo
	echo "Setting up required sysctl params..."
	config_sysctl_params

	printf '=%.0s' {1..140}
	echo
	echo "Installing containerd..."
	install_containerd

	printf '=%.0s' {1..140}
	echo
	echo "Cleaning up existing Kubernetes repository entries..."
	pre_k8s_cleanup

	printf '=%.0s' {1..140}
	echo
	echo "Updating signing key..."
	update_signing_key

	printf '=%.0s' {1..140}
	echo
	echo "Adding Kubernetes apt repository..."
	add_k8s_repo

	echo "Running apt-get update..."
	sudo apt-get update

	printf '=%.0s' {1..140}
	echo
	echo "Installing kubelet, kubeadm, kubectl..."
	install_k8s

	printf '=%.0s' {1..140}
	echo
	echo "Configuring kubelet cgroup driver to systemd..."
	config_k8s

	printf '=%.0s' {1..140}
	echo
	echo "Reloading and restarting kubelet..."
	k8s_reload_restart

	printf '=%.0s' {1..140}
	echo
	echo "Initializing Kubernetes cluster with kubeadm..."
	init_k8s_cluster

	printf '=%.0s' {1..140}
	echo
	echo "Setting up local kubeconfig..."
	setup_local_k8s

	printf '=%.0s' {1..140}
	echo
	echo "Applying Calico network plugin..."
	kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/calico.yaml
	
	monitor
	
	printf '=%.0s' {1..140}
	echo
	kubectl get pods -n kube-system
	kubectl get nodes
	
	check_helm
	
	printf '=%.0s' {1..140}
	echo
	echo "Use the following command to create new joining commands:"
	echo "kubeadm token create --print-join-command"
	echo ""
}


main