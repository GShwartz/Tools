#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Check if Docker is installed and remove only if it exists
if dpkg -l | grep -qw docker; then
    sudo apt-get remove docker docker-engine docker.io containerd runc
fi

# Update and upgrade system packages
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y upgrade

# Install necessary packages
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Set up Docker repository
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update the package database with Docker packages from the newly added repo
sudo apt-get update

# Install Docker & compose
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Add current user to Docker group
sudo usermod -aG docker $USER

# Validate Docker installation
docker --version

# Reminder for manual restart
echo "Please manually restart your system to ensure all changes are applied correctly."
