#!/bin/bash

# Check if node_exporter exists and remove it if it does
if [ -f /usr/local/bin/node_exporter ]; then
    echo "Stopping and removing existing Node Exporter..."
    sudo systemctl stop node_exporter.service
    sudo systemctl disable node_exporter.service
    sudo rm /usr/local/bin/node_exporter
    sudo rm /etc/systemd/system/node_exporter.service
    sudo systemctl daemon-reload
fi

# Download and extract node_exporter
cd /tmp
wget https://github.com/prometheus/node_exporter/releases/download/v1.8.2/node_exporter-1.8.2.linux-amd64.tar.gz
tar xvfz node_exporter-1.8.2.linux-amd64.tar.gz
sudo mv node_exporter-1.8.2.linux-amd64/node_exporter /usr/local/bin/

# Create node_exporter user
sudo useradd -rs /bin/false node_exporter
sudo chown node_exporter:node_exporter /usr/local/bin/node_exporter

# Create systemd service file for node_exporter
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