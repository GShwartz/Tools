#!/bin/bash


if [ "$EUID" -ne 0 ]; then
    exec sudo "$0" "$@"
fi

INSTALL_HELM=false
HELM_ONLY=false
APISERVER_ADVERTISE_ADDRESS=""
POD_NETWORK_CIDR=""

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -wh, --with-helm                 			Automatically install Helm after setting up the Kubernetes cluster."
    echo "  -oh, --only-helm                 			Only install Helm, skip Kubernetes setup."
    echo "  -aa, --apiserver-advertise-address [IP]  	Specify the IP address for the Kubernetes API server."
    echo "  -h, --help                       			Display this help message."
    echo
    echo "Description:"
    echo "  This script sets up a Kubernetes cluster, initializes it with kubeadm,"
    echo "  configures kubectl for the user, and applies the Calico network plugin."
    echo "  Optionally, it can also install Helm based on user input or the --with-helm flag."
    echo "  The --only-helm flag skips Kubernetes setup and only installs Helm."
    echo "  You can specify the API server's IP address, and the pod network CIDR will be"
    echo "  automatically generated based on that IP."
}

validate_ip() {
    local ip="$1"
    IFS='.' read -r -a octets <<< "$ip"
    
    # Check if there are exactly 4 octets
    if [[ ${#octets[@]} -ne 4 ]]; then
        echo "Error: Invalid IP address format."
        exit 1
    fi
    
    # Validate each octet is a number and within the valid range (0-255)
    for i in "${!octets[@]}"; do
        if ! [[ "${octets[$i]}" =~ ^[0-9]+$ ]] || [[ "${octets[$i]}" -lt 0 ]] || [[ "${octets[$i]}" -gt 255 ]]; then
            echo "Error: Invalid IP address. Each octet must be between 0 and 255."
            exit 1
        fi
    done

    # Ensure last octet is neither 0 nor above 255
    if [[ "${octets[3]}" -eq 0 ]] || [[ "${octets[3]}" -gt 255 ]]; then
        echo "Error: Invalid IP address. The last octet cannot be 0 or greater than 254."
        exit 1
    fi
}

calculate_cidr() {
    local ip="$1"
    IFS='.' read -r -a octets <<< "$ip"
    POD_NETWORK_CIDR="${octets[0]}.${octets[1]}.${octets[2]}.0/24"
}

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -wh|--with-helm)
            INSTALL_HELM=true
            ;;
        
        -oh|--only-helm)
            HELM_ONLY=true
            ;;
        
        -aa|--apiserver-advertise-address)
            APISERVER_ADVERTISE_ADDRESS="$2"
            validate_ip "$APISERVER_ADVERTISE_ADDRESS"
            calculate_cidr "$APISERVER_ADVERTISE_ADDRESS"
            shift
            ;;
        
        -h|--help)
            show_help
            exit 0
            ;;
        
        *) 
            echo "Unknown parameter passed: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done


disable_swap() {
	echo -e "[ ... ] Disabling Swap..."
	sudo swapoff -a > /dev/null 2>&1
	sudo sed -i '/ swap / s/^/# /' /etc/fstab > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  Swap Disabled."
	
}

install_dependencies() {
	echo "[ ... ] Installing dependencies..."
	sudo apt update > /dev/null 2>&1 && sudo apt install -y ufw apt-transport-https ca-certificates curl gnupg lsb-release socat conntrack > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  Dependencies installed successfully."

}

open_ports() {
	echo "[ ... ] Opening necessary ports..."
	
	sudo ufw allow 6443/tcp > /dev/null 2>&1   		# Kubernetes API server
	sudo ufw allow 2379:2380/tcp > /dev/null 2>&1  	# etcd server client API
	sudo ufw allow 10250/tcp > /dev/null 2>&1  		# Kubelet API
	sudo ufw allow 10259/tcp > /dev/null 2>&1  		# kube-scheduler
	sudo ufw allow 10257/tcp > /dev/null 2>&1  		# kube-controller-manager
	
	sudo ufw --force enable > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  Ports opened."
}

config_sysctl_params() {
	echo "[ ... ] Loading necessary kernel modules..."

	sudo modprobe overlay > /dev/null 2>&1
	sudo modprobe br_netfilter > /dev/null 2>&1
	
	sudo tee /etc/sysctl.d/kubernetes.conf > /dev/null <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
	
	echo -e " [\033[32m + \033[0m]  Modules loaded."
	
	echo "[ ... ] Applying sysctl params..."
	sudo sysctl --system > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  Sysctl applied."
}

install_containerd() {
	echo "[ ... ] Installing containerd..."
	sudo apt install -y containerd > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  containerd installed."

	echo "[ ... ] Configuring containerd..."
	sudo mkdir -p /etc/containerd
	sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  containerd configured."

	echo "[ ... ] Setting cgroup driver to systemd in containerd config..."
	sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  Configured cgroup driver."
	
	echo "[ ... ] Restarting containerd..."
	sudo systemctl restart containerd
	sudo systemctl enable containerd > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  containerd restarted successfully."
}

pre_k8s_cleanup() {
	echo "[ ... ] Cleaning up existing Kubernetes repository entries..."
	
	sudo rm -f /etc/apt/sources.list.d/kubernetes.list
	sudo rm -f /etc/apt/sources.list.d/google-cloud-sdk.list
	sudo sed -i '/kubernetes/d' /etc/apt/sources.list > /dev/null 2>&1
	sudo sed -i '/packages.cloud.google.com/d' /etc/apt/sources.list > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  Cleaning up existing Kubernetes repository entries"
}

update_signing_key() {
	echo "[ ... ] Updating signing key..."
	
	sudo mkdir -p /etc/apt/keyrings
	curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  Updating signing key."
}

add_k8s_repo() {
	echo "[ ... ] Adding Kubernetes apt repository..."
	
	echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  Adding Kubernetes apt repository."
}

install_k8s() {
	echo "[ ... ] Installing kubelet, kubeadm, kubectl..."
	sudo apt-get update > /dev/null 2>&1
	sudo apt-get install -y kubelet kubeadm kubectl > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  kubelet, kubeadm, kubectl installed successfully."
	
	echo "[ ... ] Locking current version of kubelet, kubeadm, kubectl..."
	sudo apt-mark hold kubelet kubeadm kubectl > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  Version locked."

	echo "[ ... ] Enabling and starting kubelet service..."
	sudo systemctl enable --now kubelet > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  Kubelet service enabled successfully."
}

config_k8s() {
	echo "[ ... ] Configuring kubelet cgroup driver to systemd..."
	
	sudo mkdir -p /etc/systemd/system/kubelet.service.d
	cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/20-containerd.conf  > /dev/null 2>&1
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF

	sudo mkdir -p /var/lib/kubelet
	cat <<EOF | sudo tee /var/lib/kubelet/config.yaml > /dev/null 2>&1
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd
EOF
	
	echo -e " [\033[32m + \033[0m]  Kubelet cgroup driver configured."
	
	echo "[ ... ] Configuring newer version to 'pause'..."
	sudo sed -i 's/sandbox_image = "registry\.k8s\.io\/pause:.*"/sandbox_image = "registry.k8s.io\/pause:3.9"/' /etc/containerd/config.toml > /dev/null 2>&1
	sudo systemctl restart containerd
	echo -e " [\033[32m + \033[0m]  Configured newer version to 'pause'."

}

k8s_reload_restart() {
	echo "[ ... ] Reloading and restarting kubelet..."
	sudo systemctl daemon-reload
	sudo systemctl restart kubelet
	echo -e " [\033[32m + \033[0m]  Reload and restart completed."
}

init_k8s_cluster() {
	echo "[ ... ] Initializing Kubernetes cluster with kubeadm..."
	
    if [ -z "$APISERVER_ADVERTISE_ADDRESS" ]; then
        APISERVER_ADVERTISE_ADDRESS=$(hostname -I | awk '{print $1}')
		calculate_cidr $APISERVER_ADVERTISE_ADDRESS
    fi

    if [ -z "$POD_NETWORK_CIDR" ]; then
        #POD_NETWORK_CIDR="192.168.100.0/16"
		calculate_cidr $APISERVER_ADVERTISE_ADDRESS
    fi

    sudo kubeadm init --apiserver-advertise-address="$APISERVER_ADVERTISE_ADDRESS" --pod-network-cidr="$POD_NETWORK_CIDR"
	
	echo ""
	echo -e " [\033[32m + \033[0m]  Kubernetes cluster initiated successfully."
}

setup_local_k8s() {
	echo "[ ... ] Setting up local kubeconfig..."
	
	mkdir -p $HOME/.kube
	sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	sudo chown $(id -u):$(id -g) $HOME/.kube/config > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  Local kubeconfig setup completed."
}

apply_calico() {
	echo "[ ... ] Applying Calico network plugin..."
	kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/calico.yaml > /dev/null 2>&1
	echo -e " [\033[32m + \033[0m]  Calico network plugin applied."
}

display() {
	echo -e "$(printf '=%.0s' {1..140})\n"
	echo "CURRENT NODES >> "
	kubectl get nodes
	echo ""
	
	echo "CURRENT PODS >> "
	kubectl get pods -n kube-system
	echo -e "$(printf '=%.0s' {1..140})\n"
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

manage_helm() {	
    if helm version >/dev/null 2>&1; then
        echo "Helm is already installed."
        return 0
    fi

    if [ "$INSTALL_HELM" = true ]; then
        install_helm
        helm_install_status=$?
        
        if [ $helm_install_status -eq 0 ]; then
            echo -e "[\033[32m + \033[0m] Helm was successfully installed."
            return 0
			
        else
            echo -e "[\033[31m - \033[0m] Helm installation failed."
            return 1
			
        fi
		
    else
        echo "Helm installation was skipped by the user."
        return 2
		
    fi
}

install_helm() {
    install_curl_package() {
        sudo apt-get update > /dev/null 2>&1
        sudo apt-get install -y curl > /dev/null 2>&1
    }
    
    install_git_package() {
        sudo apt-get update > /dev/null 2>&1
        sudo apt-get install -y git > /dev/null 2>&1
    }

    local helm_install_script_url="https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3"
    local helm_install_script="get_helm.sh"

    printf '=%.0s' {1..140}
    echo
    echo "[ ... ] Installing Helm..."
    
    if ! command -v curl; then
        echo "[ ... ] curl is not installed. Installing curl..."
        install_curl_package 
		echo -e " [\033[32m + \033[0m] curl was successfully installed."
    fi

    if ! command -v git; then
        echo "[ ... ] git is not installed. Installing Git..."
        install_git_package
		echo -e " [\033[32m + \033[0m] git was successfully installed."
    fi

    if curl -fsSL -o "$helm_install_script" "$helm_install_script_url" > /dev/null 2>&1; then
        chmod +x "$helm_install_script"
        
        if ./"$helm_install_script" > /dev/null 2>&1; then
            if helm version >/dev/null 2>&1; then
                rm -f "$helm_install_script"
                return 0
				
            else
                echo -e " [\033[31m - \033[0m]  Helm installation failed during verification."
                return 1
				
            fi
			
        else
            echo -e " [\033[31m - \033[0m]  Helm installation script failed during verification."
            return 1
			
        fi
		
    else
        echo -e " [\033[31m - \033[0m]  Helm installation script failed to download."
        return 1
		
    fi
}


main() {
    if [ "$HELM_ONLY" = true ]; then
		install_helm
		helm_install_status=$?

		if [ $helm_install_status -eq 0 ]; then
			# Green color for success
			echo -e "[\033[32m + \033[0m] Helm was successfully installed."
			
		else
			# Red color for failure
			echo -e "[\033[31m - \033[0m] Helm installation failed."
			
		fi

		exit $helm_install_status
	fi


    disable_swap
    install_dependencies
    open_ports
    config_sysctl_params
    install_containerd
    pre_k8s_cleanup
    update_signing_key
    add_k8s_repo
    install_k8s
    config_k8s
    k8s_reload_restart
    init_k8s_cluster
    setup_local_k8s
    apply_calico
    monitor
    display

    manage_helm

    echo -e "\n$(printf '=%.0s' {1..140})\n"
    echo "Use the following command to create new joining commands:"
    echo "sudo kubeadm token create --print-join-command"
    echo ""
    echo "If you want to install helm in a later stage you can run:"
    echo "sudo $0 -oh"
    echo ""
}

main
