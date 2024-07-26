#!/bin/bash

# Function to pause for a specified number of seconds
pause() {
    sleep "$1"
}

# Check if node_exporter exists and remove it if it does
if [ -f /usr/local/bin/node_exporter ]; then
    echo "Stopping and removing existing Node Exporter..."
    sudo systemctl stop node_exporter.service
    sudo systemctl disable node_exporter.service
    sudo rm /usr/local/bin/node_exporter
    sudo rm /etc/systemd/system/node_exporter.service
    sudo systemctl daemon-reload
    echo "Old Node Exporter removed."
    pause 2
else
    echo "No existing Node Exporter found. Proceeding with installation..."
    pause 2
fi

# Create node_exporter user if it doesn't exist
if id "node_exporter" &>/dev/null; then
    echo "User node_exporter already exists."
    pause 2
else
    sudo useradd -rs /bin/false node_exporter
    echo "User node_exporter created."
    pause 2
fi

# Download and extract node_exporter
echo "Downloading Node Exporter..."
cd /tmp
wget https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
tar xvfz node_exporter-1.8.2.linux-amd64.tar.gz
if [ $? -eq 0 ]; then
    echo "Node Exporter downloaded and extracted successfully."
    pause 2
else
    echo "Failed to download or extract Node Exporter."
    exit 1
fi

# Move the binary to /usr/local/bin
sudo mv node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter
if [ $? -eq 0 ]; then
    echo "Node Exporter moved to /usr/local/bin successfully."
    pause 2
else
    echo "Failed to move Node Exporter to /usr/local/bin."
    exit 1
fi

# Create systemd service file for node_exporter
echo "Creating systemd service file for Node Exporter..."
echo "[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter

[Install]
WantedBy=multi-user.target" | sudo tee /etc/systemd/system/node_exporter.service

# Reload systemd, enable and start node_exporter service
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter.service
if [ $? -eq 0 ]; then
    echo "Node Exporter service started and enabled successfully."
    pause 2
else
    echo "Failed to start and enable Node Exporter service."
    exit 1
fi

echo "Node Exporter installation and setup completed successfully."
pause 2