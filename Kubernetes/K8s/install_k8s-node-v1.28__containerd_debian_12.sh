#!/bin/bash


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

setup_local_k8s() {
	mkdir -p $HOME/.kube
	sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
	sudo chown $(id -u):$(id -g) $HOME/.kube/config
}


main() {
	echo "Disabling Swap..."
	disable_swap

	echo "Running update..."
	sudo apt update

	printf '=%.0s' {1..140}
	echo ""
	echo "Installing dependencies..."
	install_dependencies

	printf '=%.0s' {1..140}
	echo ""
	echo "Opening necessary ports..."
	open_ports

	printf '=%.0s' {1..140}
	echo ""
	echo "Setting up required sysctl params..."
	config_sysctl_params

	printf '=%.0s' {1..140}
	echo ""
	echo "Installing containerd..."
	install_containerd

	printf '=%.0s' {1..140}
	echo ""
	echo "Cleaning up existing Kubernetes repository entries..."
	pre_k8s_cleanup

	printf '=%.0s' {1..140}
	echo ""
	echo "Updating signing key..."
	update_signing_key

	printf '=%.0s' {1..140}
	echo ""
	echo "Adding Kubernetes apt repository..."
	add_k8s_repo

	echo "Running apt-get update..."
	sudo apt-get update

	printf '=%.0s' {1..140}
	echo ""
	echo "Installing kubelet, kubeadm, kubectl..."
	install_k8s

	printf '=%.0s' {1..140}
	echo ""
	echo "Configuring kubelet cgroup driver to systemd..."
	config_k8s

	printf '=%.0s' {1..140}
	echo ""
	echo "Reloading and restarting kubelet..."
	k8s_reload_restart
	
	
	echo ""
	echo "Run the following command to join this node to a cluster: "
	echo "sudo kubeadm join <ip-address>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<token>"
	echo ""
	echo "Or you can retrieve the full command from the k8s master by running: "
	echo "kubeadm token create --print-join-command"
	echo ""

}


main
