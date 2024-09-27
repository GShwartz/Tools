#!/bin/bash

: <<'COMMENT'
	Machine Pre Setup:
		Hardware: 
			Min 2 CPU, 4GB RAM
			
		Software:
			curl, sudo - set no passwd for user & usermod to sudo group

		If the machine will be a CI/CD agent:
			- add current user to sudo group:
				sudo usermod -aG sudo $(whoami)
				
			- use visudo to remove the need for sudo password:
				username	ALL=(ALL) NOPASSWD:ALL
				
			- Install git docker-ce to install agent pre-dependencies.
			- start docker service
			- login to dockerhub account (if exists)
COMMENT

if [ "$EUID" -ne 0 ]; then
	exec sudo "$0" "$@"
fi
	
SCRIPT_DIR=$(dirname "$0")
LISTENER_NODE="$SCRIPT_DIR/node_listener.yml"
LISTENER_DEFAULT_TIMER=60
MODIFY_CONTROL_PLANE=false
IS_MASTER=false
INSTALL_HELM=false
HELM_ONLY=false
APISERVER_ADVERTISE_ADDRESS=""
POD_NETWORK_CIDR=""

show_help() {
    printf "Usage: $0 [OPTIONS]\n\n"
    printf "Default setting is set to install a WORKER node.\n\n"
    printf "Options:\n"
    printf "  -h, --help                       			Display this help message.\n"
    printf "  -m, --master 						Install K8s master.\n"
    printf "  -wh, --with-helm                	 		Automatically install Helm after setting up the Kubernetes cluster.\n"
    printf "  -oh, --only-helm                 			Only install Helm, skip Kubernetes setup.\n"
    printf "  -aa, --apiserver-advertise-address [IP] 		Specify the IP address for the Kubernetes API server.\n"
    printf "  -st, --sleep-time [SECONDS]        			Specify the sleep time (in seconds) for the node listener between checks. Default is 60 seconds.\n"
    printf "  -mcp, --modify-control-plane      			Allow the node listener to modify control-plane nodes (default is to skip control-plane nodes).\n\n"
    printf "Description:\n"
    printf "  This script sets up a Kubernetes cluster, initializes it with kubeadm,\n"
    printf "  configures kubectl for the user, and applies the Calico network plugin.\n"
    printf "  Optionally, it can also install Helm based on user input or the --with-helm flag.\n"
    printf "  The --only-helm flag skips Kubernetes setup and only installs Helm.\n"
    printf "  You can specify the API server's IP address, and the pod network CIDR will be\n"
    printf "  automatically generated based on that IP.\n"
    printf "  Additionally, you can customize the behavior of the node listener using the\n"
    printf "  --sleep-time and --modify-control-plane flags.\n"
}

echo_message() {
    local status=$1
    local message=$2

    case "$status" in
        INFO)
            printf "[ ... ] %s\n" "${message}"
            ;;
        
        DEBUG)
            printf "[ >> ] %s\n" "${message}"
            ;;
        
        WARN)
            printf " [\033[33m ! \033[0m] %s\n" "${message}"
            ;;
            
        SUCCESS)
            printf " [\033[32m + \033[0m] %s\n" "${message}"
            ;;
            
        ERROR)
            printf " [\033[31m - \033[0m] %s\n" "${message}"
            ;;
            
        *)
            printf " [\033[33m ? \033[0m] Unknown status: %s\n" "${message}"
            ;;
    esac
}

validate_ip() {
    local ip="$1"
    IFS='.' read -r -a octets <<< "$ip"
    
    if [[ ${#octets[@]} -ne 4 ]]; then
		echo_message ERROR "Error: Invalid IP address format."
        exit 1
    fi
    
    for i in "${!octets[@]}"; do
        if ! [[ "${octets[$i]}" =~ ^[0-9]+$ ]] || [[ "${octets[$i]}" -lt 0 ]] || [[ "${octets[$i]}" -gt 255 ]]; then
            echo_message ERROR "Error: Invalid IP address. Each octet must be between 0 and 255."
            exit 1
        fi
    done

    if [[ "${octets[3]}" -eq 0 ]] || [[ "${octets[3]}" -gt 255 ]]; then
        echo_message ERROR "Error: Invalid IP address. The last octet cannot be 0 or greater than 254."
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
        -m|--master)
            IS_MASTER=true
            ;;
        
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
        
        -st|--sleep-time)
            LISTENER_DEFAULT_TIMER="$2"
            if ! [[ "$LISTENER_DEFAULT_TIMER" =~ ^[0-9]+$ ]]; then
                echo_message ERROR "Invalid sleep time. It must be a positive integer."
                exit 1
            fi
            shift
            ;;
        
        -mcp|--modify-control-plane)
            MODIFY_CONTROL_PLANE=true
            ;;
        
        -h|--help)
            show_help
            exit 0
            ;;
        
        *) 
            echo_message ERROR "Unknown parameter passed: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

disable_swap() {
    echo_message INFO "Disabling Swap..."
    if free | grep -q 'Swap:[[:space:]]*0'; then
        echo_message WARN "Swap is already disabled."
		
    else
        if sudo swapoff -a > /dev/null 2>&1; then
            echo_message SUCCESS "Swapoff command executed successfully."
			
        else
            echo_message ERROR "Failed to disable swap. Please check permissions."
            return 1
        fi
    fi

    if grep -E '\s+swap\s+' /etc/fstab > /dev/null; then
        if sudo sed -i '/ swap / s/^/# /' /etc/fstab > /dev/null 2>&1; then
            echo_message SUCCESS "Swap entry in /etc/fstab commented out successfully."
        
		else
            echo_message ERROR "Failed to modify /etc/fstab. Please check file permissions."
            return 1
        fi
		
    else
        echo_message ERROR "No swap entry found in /etc/fstab."
		
    fi

    echo_message SUCCESS "Swap Disabled."
}

install_dependencies() {
	echo_message INFO "Installing dependencies..."
	sudo apt update > /dev/null 2>&1 && sudo apt install -y ufw apt-transport-https ca-certificates curl gnupg lsb-release socat conntrack > /dev/null 2>&1
	echo_message SUCCESS "Dependencies installed successfully."
}

open_ports() {
	echo_message INFO "Opening necessary ports..."
	sudo ufw allow 6443/tcp > /dev/null 2>&1   		# Kubernetes API server
	sudo ufw allow 2379:2380/tcp > /dev/null 2>&1  	# etcd server client API
	sudo ufw allow 10250/tcp > /dev/null 2>&1  		# Kubelet API
	sudo ufw allow 10259/tcp > /dev/null 2>&1  		# kube-scheduler
	sudo ufw allow 10257/tcp > /dev/null 2>&1  		# kube-controller-manager
	
	sudo ufw --force enable > /dev/null
	echo_message SUCCESS "Ports opened."
}

config_sysctl_params() {
	echo_message INFO "Loading necessary kernel modules..."

	sudo modprobe overlay > /dev/null
	sudo modprobe br_netfilter > /dev/null
	
	sudo tee /etc/sysctl.d/kubernetes.conf > /dev/null <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
EOF
	
	echo_message SUCCESS "Kernel modules loaded."
	
	echo_message INFO "Applying sysctl params..."
	sudo sysctl --system > /dev/null
	echo_message SUCCESS "Sysctl applied successfully."
}

install_containerd() {
	echo_message INFO "Installing containerd..."
	sudo apt install -y containerd > /dev/null 2>&1
	echo_message SUCCESS "containerd installed."

	echo_message INFO "Configuring containerd..."
	sudo mkdir -p /etc/containerd
	sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
	echo_message SUCCESS "containerd configured."

	echo_message INFO "Setting cgroup driver to systemd in containerd config..."
	sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml > /dev/null
	echo_message SUCCESS "Configured cgroup driver."
	
	echo_message INFO "Restarting containerd..."
	sudo systemctl restart containerd
	sudo systemctl enable containerd > /dev/null
	echo_message SUCCESS "containerd restarted successfully."
}

pre_k8s_cleanup() {
	echo_message INFO "Cleaning up existing Kubernetes repository entries..."
	
	sudo rm -f /etc/apt/sources.list.d/kubernetes.list
	sudo rm -f /etc/apt/sources.list.d/google-cloud-sdk.list
	sudo sed -i '/kubernetes/d' /etc/apt/sources.list > /dev/null 2>&1
	sudo sed -i '/packages.cloud.google.com/d' /etc/apt/sources.list > /dev/null 2>&1
	echo_message SUCCESS "Kubernetes repository entries cleaned."
}

update_signing_key() {
	echo_message INFO "Updating signing key..."
	
	sudo mkdir -p /etc/apt/keyrings
	curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg > /dev/null 2>&1
	echo_message SUCCESS "Updating signing key."
}

add_k8s_repo() {
	echo_message INFO "Adding Kubernetes apt repository..."
	
	echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
	echo_message SUCCESS "Added Kubernetes apt repository."
}

install_k8s() {
	echo_message INFO "Installing kubelet, kubeadm, kubectl..."
	sudo apt-get update > /dev/null 2>&1
	sudo apt-get install -y kubelet kubeadm kubectl > /dev/null 2>&1
	echo_message SUCCESS "kubelet, kubeadm, kubectl installed successfully."
	
	echo_message INFO "Locking current version of kubelet, kubeadm, kubectl..."
	sudo apt-mark hold kubelet kubeadm kubectl > /dev/null
	echo_message SUCCESS "Version locked."

	echo_message INFO "Enabling and starting kubelet service..."
	sudo systemctl enable --now kubelet > /dev/null
	echo_message SUCCESS "Kubelet service enabled successfully."
}

config_k8s() {
	echo_message INFO "Configuring kubelet cgroup driver to systemd..."
	
	sudo mkdir -p /etc/systemd/system/kubelet.service.d
	cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/20-containerd.conf  > /dev/null
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime=remote --container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF

	sudo mkdir -p /var/lib/kubelet
	cat <<EOF | sudo tee /var/lib/kubelet/config.yaml > /dev/null
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
cgroupDriver: systemd
EOF
	
	echo_message SUCCESS "Kubelet cgroup driver configured."
	
	echo_message INFO "Configuring newer version to 'pause'..."
	sudo sed -i 's/sandbox_image = "registry\.k8s\.io\/pause:.*"/sandbox_image = "registry.k8s.io\/pause:3.9"/' /etc/containerd/config.toml > /dev/null
	sudo systemctl restart containerd
	echo_message SUCCESS "Configured newer version to 'pause'."

}

k8s_reload_restart() {
	echo_message INFO "Reloading and restarting kubelet..."
	sudo systemctl daemon-reload
	sudo systemctl restart kubelet
	echo_message SUCCESS "Reload and restart completed."
}

init_k8s_cluster() {
	echo_message INFO "Initializing Kubernetes cluster with kubeadm..."
	
    if [ -z "$APISERVER_ADVERTISE_ADDRESS" ]; then
        APISERVER_ADVERTISE_ADDRESS=$(hostname -I | awk '{print $1}')
		calculate_cidr $APISERVER_ADVERTISE_ADDRESS
    fi

    if [ -z "$POD_NETWORK_CIDR" ]; then
		calculate_cidr $APISERVER_ADVERTISE_ADDRESS
    fi
	
	echo_message DEBUG "API server advertise address: ${APISERVER_ADVERTISE_ADDRESS} | Pod Network CIDR: ${POD_NETWORK_CIDR}"
    sudo kubeadm init --apiserver-advertise-address="$APISERVER_ADVERTISE_ADDRESS" --pod-network-cidr="$POD_NETWORK_CIDR" -v=0
	
	echo ""
	echo_message SUCCESS "Kubernetes cluster initiated successfully."
}

setup_local_k8s() {
	echo_message INFO "Setting up local kubeconfig..."
	mkdir -p $HOME/.kube
	sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	sudo chown $(id -u):$(id -g) $HOME/.kube/config > /dev/null
	echo_message SUCCESS "Local kubeconfig setup completed."
}

apply_calico() {
	echo_message INFO "Applying Calico network plugin..."
	kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/calico.yaml > /dev/null 2>&1
	echo_message SUCCESS "Calico network plugin applied."
}

display() {
	echo -e "$(printf '=%.0s' {1..100})"
	echo ""
	echo "CURRENT NODES >> "
	kubectl get nodes
	echo ""
	
	echo "CLUSTER PODS >> "
	kubectl get pods -A
	echo ""
	
}

are_all_nodes_ready() {
    local max_retries=5
    local retry_delay=10
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        local nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}')
        if [ -z "$nodes" ]; then
			echo_message ERROR "Attempt $attempt/$max_retries failed: Unable to get nodes status."
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

            spin "Nodes not ready. Waiting..." &
            SPIN_PID=$!
            sleep $retry_delay
            kill $SPIN_PID 2>/dev/null
        fi
    done

	echo_message ERROR "Failed to get all nodes in Ready status after $max_retries attempts."
    return 1
}

are_all_system_pods_ready() {
    local max_retries=5
    local retry_delay=10
    local attempt=1

    while [ $attempt -le $max_retries ]; do
        local pods=$(kubectl get pods --namespace kube-system --no-headers 2>/dev/null)
        if [ -z "$pods" ]; then
			echo_message ERROR "Attempt $attempt/$max_retries failed: Unable to get kube-system pods."
            attempt=$((attempt+1))
            sleep $retry_delay
			
        else
            local all_running=true
            echo "$pods" | awk '{split($2, a, "/"); if (a[1] != a[2] || $3 != "Running") exit 1}' || all_running=false

            if [ "$all_running" = true ]; then
                return 0
            fi

            spin "Some kube-system pods are not running. Waiting..." &
            SPIN_PID=$!
            sleep $retry_delay
            kill $SPIN_PID 2>/dev/null
        fi
    done

	echo_message ERROR "Failed to get all kube-system pods in Running status after $max_retries attempts."
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
			kill $SPIN_PID 2>/dev/null

			printf "\n"
			echo_message SUCCESS "All nodes and system pods are ready."
			printf "\n"

			break
			
		else
			spin "Waiting for nodes and system pods to become ready..." &
			SPIN_PID=$!

			sleep 5

			kill $SPIN_PID 2>/dev/null
		fi
	done
}

create_node_listener_service() {
	echo_message INFO "Creating node listener service..."
	cat <<EOF | sudo kubectl apply -f - > /dev/null
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-labeler-sa
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-labeler-clusterrole
rules:
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["get", "list", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: node-labeler-clusterrolebinding
subjects:
- kind: ServiceAccount
  name: node-labeler-sa
  namespace: default
roleRef:
  kind: ClusterRole
  name: node-labeler-clusterrole
  apiGroup: rbac.authorization.k8s.io
EOF

	echo_message SUCCESS "Service created successfully."
}

create_node_listener() {
    echo_message INFO "Creating a node listener ConfigMap file..."
    cat <<EOF > $LISTENER_NODE
apiVersion: v1
kind: Pod
metadata:
  name: node-labeler
  namespace: default
  
spec:
  serviceAccountName: node-labeler-sa
  tolerations:
  - key: "node-role.kubernetes.io/control-plane"
    operator: "Exists"
    effect: "NoSchedule"
  
  containers:
  - name: label-nodes
    image: bitnami/kubectl:latest
    command:
      - /bin/bash
      - -c
    args:
      - |
        while true; do
          echo "Checking and labeling nodes..."
          for node in \$(kubectl get nodes --no-headers | awk '{print \$1}'); do
            control_plane_taint=\$(kubectl get node \$node --output=jsonpath='{.metadata.labels["node-role.kubernetes.io/control-plane"]}')
            if [[ "$MODIFY_CONTROL_PLANE" == "false" && "\$control_plane_taint" == "true" ]]; then
              echo "Skipping control-plane node: \$node"
              continue
            fi

            if [[ \$(kubectl get node \$node --output=jsonpath='{.metadata.labels["node-role.kubernetes.io/worker"]}') == "" ]]; then
              kubectl label node \$node node-role.kubernetes.io/worker= --overwrite
              echo "Labeled node \$node as worker."
            fi
          done
          echo "Sleeping for $LISTENER_DEFAULT_TIMER seconds..."
          sleep $LISTENER_DEFAULT_TIMER
        done
  restartPolicy: Always
EOF

    if [ $? -eq 0 ]; then
        echo_message SUCCESS "Node listener file created successfully at $LISTENER_NODE."
        return 0
    else
        echo_message ERROR "Error creating the node listener file. Exit code: $?"
        return 1
    fi
}

apply_node_listener() {
	echo_message INFO "Applying $LISTENER_NODE..."
	sudo kubectl apply -f "${LISTENER_NODE}" > /dev/null
	echo_message SUCCESS "$LISTENER_NODE applied successfully."
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

    echo -e "$(printf '=%.0s' {1..100})"
	echo_message INFO "Installing Helm..."
    
    if ! command -v curl > /dev/null 2>&1; then
		echo_message INFO "curl is not installed. Installing curl..."
        install_curl_package 
		echo_message SUCCESS "curl was successfully installed."
    fi

    if ! command -v git > /dev/null 2>&1; then
		echo_message INFO "git is not installed. Installing Git..."
        install_git_package
		echo_message SUCCESS "git was successfully installed."
    fi

    if curl -fsSL -o "$helm_install_script" "$helm_install_script_url" > /dev/null; then
        chmod +x "$helm_install_script"
        
        if ./"$helm_install_script" > /dev/null; then
            if helm version >/dev/null 2>&1; then
                rm -f "$helm_install_script"
                return 0
				
            else
				echo_message ERROR "Helm installation failed during verification."
                return 1
				
            fi
			
        else
			echo_message ERROR "Helm installation script failed during verification."
            return 1
			
        fi
		
    else
		echo_message ERROR "Helm installation script failed to download."
        return 1
		
    fi
}

manage_helm() {	
    if helm version >/dev/null 2>&1; then
		echo -e "$(printf '=%.0s' {1..100})\n"
        echo_message DEBUG "Helm is already installed."
        return 0
    fi
		
	if [ "$HELM_ONLY" = true ]; then
		install_helm
		helm_install_status=$?
	
		if [ $helm_install_status -eq 0 ]; then
			HELM_VER=$(helm version --short 2>/dev/null)
			if [ -n "$HELM_VER" ]; then
				echo_message DEBUG "HELM Version: ${HELM_VER}"
				echo_message SUCCESS "Helm was successfully installed."
				exit 0

			else
				echo_message ERROR "Unable to get Helm version."
				exit 1

			fi
			
		else
			echo_message ERROR "Helm installation failed."
			exit 1
			
		fi
	fi
	
    if [ "$INSTALL_HELM" = true ]; then
        install_helm
        helm_install_status=$?
        
        if [ $helm_install_status -eq 0 ]; then
			HELM_VER=$(helm version --short 2>/dev/null)
			if [ -n "$HELM_VER" ]; then
				echo_message DEBUG "HELM Version: ${HELM_VER}"
				echo_message SUCCESS "Helm was successfully installed."
				return 0

			else
				echo_message ERROR "Unable to get Helm version."
				return 1

			fi
		fi
		
    else
		echo -e "$(printf '=%.0s' {1..100})\n"
        echo_message DEBUG "Helm installation was skipped by the user."
        return 2
		
    fi
}

taint_nodes() {
	echo_message INFO "Tainting nodes..."
	sudo kubectl taint nodes $(hostname) node-role.kubernetes.io/control-plane:NoSchedule --overwrite=true
	echo_message SUCCESS "Nodes tainted successfully."
}

manage_worker_installation() {
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
}

manage_master_installation() {
	init_k8s_cluster
	setup_local_k8s
	taint_nodes
	apply_calico
	create_node_listener_service
	create_node_listener
	apply_node_listener
	monitor
	display
}

manage_pre_run() {
	if [[ -f /etc/os-release ]]; then
		. /etc/os-release
		OS_NAME=$NAME
		OS_VERSION=$VERSION_ID
		echo_message DEBUG "Detected OS: $OS_NAME $OS_VERSION"
		
	else
		echo_message ERROR "Unable to detect OS version."
		exit 1
		
	fi

	if [[ "$OS_NAME" = "Debian GNU/Linux" || "$OS_NAME" = "Ubuntu" ]]; then
		if [[ "$OS_VERSION" != "11" && "$OS_VERSION" != "12" && "$OS_VERSION" != "22.04" && "$OS_VERSION" != "24.04" ]]; then
			echo_message ERROR "Unsupported OS version: $OS_NAME $OS_VERSION"
			exit 1
			
		fi
		
	else
		echo_message ERROR "Unsupported OS: $OS_NAME"
		exit 1
		
	fi
	
	if [ "$HELM_ONLY" = true ]; then
		manage_helm
	
	fi
}

main() {
	manage_pre_run
	
	if [ "$IS_MASTER" = true ]; then
		manage_worker_installation
		manage_master_installation
		manage_helm
		
		echo -e "$(printf '=%.0s' {1..100})\n"
		printf "Use the following command to create new joining commands:\n"
		printf "sudo kubeadm token create --print-join-command\n\n"
		echo ""
		
		exit 0
	
	else
		manage_worker_installation
		manage_helm
		
		echo -e "$(printf '=%.0s' {1..100}\n)"
		echo_message DEBUG "Run the following command in the master machine:"
		echo_message DEBUG "sudo kubeadm token create --print-join-command"
		echo_message DEBUG ""
		echo_message DEBUG "Copy the output and run it on the agent machine."
		echo ""
		
		exit 0
	fi
}


main
