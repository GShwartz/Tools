#!/bin/bash

# Function to display help/usage information
display_usage() {
    echo "Usage:"
    echo "  Single user mode: $0 -u <username> -p <password> -s <ssh_pwauth true or false> [-pk <package1,package2,...>]"
    echo "  Multiple users mode: $0 -n <number_of_users> [-pk <package1,package2,...>] (interactive mode)"
    echo "  Additional options: [-cf <config_file_path> -cc <content_file_path>] [-dr <disable_root true or false>]"
    echo ""
    echo "Options:"
    echo "  -u  	Username for the user to be created"
    echo "  -p  	Password for the user to be created"
    echo "  -s  	Whether to enable SSH password authentication ('true' or 'false')"
    echo "  -n  	Number of users to be created (for interactive mode)"
    echo "  -P 	    Comma-separated list of packages to be installed"
    echo "  -F   	Path where the configuration file should be written on the system"
    echo "  -C  	Local file path from which to read the content to be written to the config file"
    echo "  -r  	Default value to disable root login ('true' or 'false')"
    echo ""
    echo "Example:"
    echo "  $0 -u username -p password -s true -P curl,git -r false"
}

# Function to check for the existence of a local SSH key
check_ssh_key() {
    if [[ ! -f "$HOME/.ssh/id_rsa.pub" ]]; then
        echo "Error: No local SSH key found at $HOME/.ssh/id_rsa.pub."
        echo "Please generate an SSH key pair before running this script."
        exit 1
    fi
}

# Check if no arguments were provided
if [ $# -eq 0 ]; then
    display_usage
    exit 1
fi

# Initialize variables
NUM_USERS=""           
USERNAME=""             
PASSWORD=""             
SSH_PWAUTH=""           
PACKAGES=""             
CONFIG_FILE_PATH=""     
CONTENT_FILE_PATH=""    
DISABLE_ROOT="true"     

# Process command-line options
while getopts 'u:p:s:n:P:F:C:r:' flag; do
  case "${flag}" in
    n) NUM_USERS="${OPTARG}" ;;
    u) USERNAME="${OPTARG}" ;;
    p) PASSWORD="${OPTARG}" ;;
    s) SSH_PWAUTH="${OPTARG}" ;;
    P) PACKAGES="${OPTARG}" ;;
    F) CONFIG_FILE_PATH="${OPTARG}" ;;
    C) CONTENT_FILE_PATH="${OPTARG}" ;;
    r) DISABLE_ROOT="${OPTARG}" ;;
    *) display_usage
       exit 1 ;;
  esac
done

# Debugging output to verify the input
echo "Debugging Information:"
echo "USERNAME: $USERNAME"
echo "PASSWORD: [hidden]"
echo "SSH_PWAUTH: $SSH_PWAUTH"
echo "NUM_USERS: $NUM_USERS"
echo "PACKAGES: $PACKAGES"
echo "CONFIG_FILE_PATH: $CONFIG_FILE_PATH"
echo "CONTENT_FILE_PATH: $CONTENT_FILE_PATH"
echo "DISABLE_ROOT: $DISABLE_ROOT"

# Check for the existence of a local SSH key if SSH password authentication is false
if [[ "$SSH_PWAUTH" == "false" ]]; then
    check_ssh_key
fi

# Initialize the user-data file
cat <<EOF >user-data.yaml
#cloud-config
EOF

# Add users section
if [[ -n "$USERNAME" && -n "$PASSWORD" ]]; then
    echo "users:" >> user-data.yaml
    # Generating password hash
    password_hash=$(openssl passwd -6 "$PASSWORD")
    cat <<EOF >>user-data.yaml
  - name: $USERNAME
    gecos: Custom User
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
    lock_passwd: false
    passwd: $password_hash
    shell: /bin/bash
EOF

    if [[ "$SSH_PWAUTH" == "false" && -f "$HOME/.ssh/id_rsa.pub" ]]; then
        echo "    ssh-authorized-keys:" >> user-data.yaml
        echo "      - $(<"$HOME/.ssh/id_rsa.pub")" >> user-data.yaml
    fi
fi

# Add ssh_pwauth and disable_root configurations
echo "" >> user-data.yaml
echo "ssh_pwauth: $SSH_PWAUTH" >> user-data.yaml
echo "disable_root: $DISABLE_ROOT" >> user-data.yaml

# Convert package list from comma-separated to space-separated for cloud-init
IFS=',' read -r -a PACKAGE_ARRAY <<< "$PACKAGES"

# Append packages if provided
if [[ -n "$PACKAGES" ]]; then
	echo "" >> user-data.yaml
    echo "packages:" >> user-data.yaml
    for pkg in "${PACKAGE_ARRAY[@]}"; do
        echo "  - $pkg" >> user-data.yaml
    done
fi

# Write files if provided
if [[ -n "$CONFIG_FILE_PATH" && -n "$CONTENT_FILE_PATH" && -f "$CONTENT_FILE_PATH" ]]; then
	echo "" >> user-data.yaml
    echo "write_files:" >> user-data.yaml
    echo "  - path: $CONFIG_FILE_PATH" >> user-data.yaml
    echo "    content: |" >> user-data.yaml
    while IFS= read -r line || [[ -n "$line" ]]; do
        echo "      $line" >> user-data.yaml
    done < "$CONTENT_FILE_PATH"
fi

echo "User-data file has been generated."
