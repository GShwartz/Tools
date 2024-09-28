# Kubernetes Cluster Setup Script

This Bash script automates the process of setting up a Kubernetes cluster, including the installation of necessary dependencies, Kubernetes, and optional Helm deployment. It supports configuring either a master or worker node and can be tailored to your environment.

## Prerequisites

Ensure that the machine where this script is run meets the following requirements:

### Hardware
- Minimum: 2 CPUs, 4GB RAM

To prepare the machine as a CI/CD agent, ensure:
- The user is added to the sudo group:
  ```bash
  sudo usermod -aG sudo $(whoami)
  ```
- Passwordless `sudo` is enabled by adding the following line in `visudo`:
  ```text
  username ALL=(ALL) NOPASSWD:ALL
  ```
- Docker and Git are installed:
  ```bash
  sudo apt install git docker-ce -y
  sudo systemctl start docker
  docker login
  ```

## Usage

The default setting installs a **worker node**. You can customize the setup with the following options:

```bash
./bundle.sh [OPTIONS]
```

### Options

| Option | Description |
|--------|-------------|
| `-h, --help` | Display the help message |
| `-m, --master` | Install Kubernetes master node |
| `-s, --sleep [SECONDS]` | Set sleep time between node scans (default: 60 seconds) |
| `-wh, --with-helm` | Install Helm after Kubernetes cluster setup |
| `-oh, --only-helm` | Install only Helm, skipping Kubernetes setup |
| `-aaa, --apiserver-advertise-address [IP]` | Specify the Kubernetes API server's IP address |

### Example

Install a Kubernetes master node with Helm:

```bash
./bundle.sh --master --with-helm
```

## Features

- Automatically installs Kubernetes (`kubeadm`, `kubectl`, `kubelet`) and configures the environment.
- Optionally installs Helm for managing Kubernetes applications.
- Configures the Calico network plugin by default.
- Supports both master and worker node setup.
- Can be integrated into CI/CD environments.

## Kubernetes Cluster Setup Steps

1. **Disable Swap:** Ensures swap is disabled for Kubernetes to function properly.
2. **Install Dependencies:** Installs essential packages (`ufw`, `curl`, `socat`, `containerd`, etc.).
3. **Open Necessary Ports:** Opens ports for the Kubernetes API server, etcd, and other essential services.
4. **Kubernetes Initialization:** Sets up the master node using `kubeadm` and applies the Calico network plugin.
5. **Helm Setup (Optional):** Installs Helm if specified.
6. **Node Monitoring:** Sets up a node listener to label and monitor the nodes for readiness.

## Troubleshooting

- Ensure the correct version of Ubuntu or Debian is used: `Debian 11`, `Debian 12`, `Ubuntu 22.04`, or `Ubuntu 24.04`.
- For joining worker nodes to the master node, run the following on the master:
  ```bash
  sudo kubeadm token create --print-join-command
  ```
  Copy and run the output command on the worker nodes.

## License

This script is open-source and distributed under the MIT License.
