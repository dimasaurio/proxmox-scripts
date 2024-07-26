#!/bin/bash

# Prompt for LXC ID if not set
if [[ -z "$LXC_ID" ]]; then
    read -p "Enter the LXC ID you want to use: " LXC_ID
fi
echo "You entered LXC ID: '$LXC_ID'"
if ! [[ "$LXC_ID" =~ ^[0-9]+$ ]]; then
    echo "Error: LXC ID must be an integer."
    exit 1
fi

# Prompt for LXC container name if not set
if [ -z "$LXC_NAME" ]; then
    read -p "Enter the name for the LXC container: " LXC_NAME
fi

# Prompt for root password if not set
if [ -z "$ROOT_PASSWORD" ]; then
    while true; do
        read -s -p "Enter the root password for the LXC container: " ROOT_PASSWORD
        echo
        read -s -p "Confirm the root password: " CONFIRM_PASSWORD
        echo
        if [ "$ROOT_PASSWORD" == "$CONFIRM_PASSWORD" ]; then
            echo "Password confirmed."
            break
        else
            echo "Passwords do not match. Please try again."
        fi
    done
fi

# Check for the Ubuntu 22.04 template
template=$(pveam list local | grep ubuntu-22.04-standard_22.04-1_amd64.tar.zst | awk '{print $1}')
if [ -z "$template" ]; then
    echo "Ubuntu 22.04 template not found. Attempting to download it..."
    pveam update && pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst
    # Recheck for the template
    template=$(pveam list local | grep ubuntu-22.04-standard_22.04-1_amd64.tar.zst | awk '{print $1}')
    if [ -z "$template" ]; then
        echo "Failed to download the Ubuntu 22.04 template. Please check your network or storage configuration."
        exit 1
    fi
fi

# Prompt for WordPress database details if not set
if [ -z "$WP_DBNAME" ]; then
    read -p "Enter the WordPress database name: " WP_DBNAME
fi
if [ -z "$WP_DBUSER" ]; then
    read -p "Enter the WordPress database username: " WP_DBUSER
fi
if [ -z "$WP_DBPASS" ]; then
    read -s -p "Enter the WordPress database password: " WP_DBPASS
    echo
fi

# Prompt for installation type if not set
if [ -z "$INSTALL_CHOICE" ]; then
    echo "Select installation type:"
    echo "1) Fast Installation (Default settings: 25GB disk, 2GB RAM, 1 CPU Core, DHCP)"
    echo "2) Customized Installation"
    read -p "Enter your choice (1 or 2): " INSTALL_CHOICE
fi

case $INSTALL_CHOICE in
    1)
        echo "Proceeding with Fast Installation..."
        disk_size="25"  # Default disk size
        memory="2048"    # Default memory in MB
        cores="1"        # Default number of CPU cores
        net_mode="dhcp"  # Default network mode
        ;;
    2)
        echo "Proceeding with Customized Installation..."
        if [ -z "$DISK_SIZE" ]; then
            read -p "Enter disk size in G(e.g., 25): " DISK_SIZE
        fi
        if [ -z "$MEMORY" ]; then
            read -p "Enter memory size in MB (e.g., 2048): " MEMORY
        fi
        if [ -z "$CORES" ]; then
            read -p "Enter number of CPU cores (e.g., 1): " CORES
        fi
        if [ -z "$NET_MODE" ]; then
            read -p "Enter network mode (dhcp or static): " NET_MODE
        fi
        if [ "$NET_MODE" == "static" ]; then
            if [ -z "$IPV4" ]; then
                read -p "Enter IPv4 address (e.g., 192.168.1.100/24): " IPV4
            fi
            if [ -z "$GW" ]; then
                read -p "Enter gateway (e.g., 192.168.1.1): " GW
            fi
        fi
        ;;
    *)
        echo "Invalid choice. Exiting..."
        exit 1
        ;;
esac

# Create the LXC container with the specified name
if [ "$NET_MODE" == "dhcp" ]; then
    pct create $LXC_ID $template --hostname $LXC_NAME --password $ROOT_PASSWORD --cores $cores --memory $memory --rootfs local-lvm:${DISK_SIZE} --net0 name=eth0,bridge=vmbr0,ip=dhcp
else
    pct create $LXC_ID $template --hostname $LXC_NAME --password $ROOT_PASSWORD --cores $cores --memory $memory --rootfs local-lvm:${DISK_SIZE} --net0 name=eth0,bridge=vmbr0,ip=$IPV4,gw=$GW
fi

# Start the container
pct start $LXC_ID

# Allow some time for the network to come up
sleep 10

# Update and upgrade packages
pct exec $LXC_ID -- apt-get update && apt-get upgrade -y

# Install Nginx, PHP, and MySQL
pct exec $LXC_ID -- apt-get install nginx php-fpm php-mysql mysql-server -y

# Create a WordPress database and user with the provided credentials
pct exec $LXC_ID -- mysql -e "CREATE DATABASE ${WP_DBNAME}; CREATE USER '${WP_DBUSER}'@'localhost' IDENTIFIED BY '${WP_DBPASS}'; GRANT ALL PRIVILEGES ON ${WP_DBNAME}.* TO '${WP_DBUSER}'@'localhost'; FLUSH PRIVILEGES;"

# Download and configure WordPress
pct exec $LXC_ID -- bash -c "wget https://wordpress.org/latest.tar.gz -O /tmp/wordpress.tar.gz && tar xzf /tmp/wordpress.tar.gz -C /var/www/html --strip-components=1 && chown -R www-data:www-data /var/www/html"
pct exec $LXC_ID -- bash -c "cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php"
pct exec $LXC_ID -- bash -c "sed -i 's/database_name_here/${WP_DBNAME}/g' /var/www/html/wp-config.php"
pct exec $LXC_ID -- bash -c "sed -i 's/username_here/${WP_DBUSER}/g' /var/www/html/wp-config.php"
pct exec $LXC_ID -- bash -c "sed -i 's/password_here/${WP_DBPASS}/g' /var/www/html/wp-config.php"

# Configure Nginx for WordPress
pct exec $LXC_ID -- bash -c "echo 'server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.php index.html index.htm;
    server_name _;

    location / {
        try_files \$uri \$uri/ /index.php\$is_args\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}' > /etc/nginx/sites-available/wordpress"

pct exec $LXC_ID -- bash -c "chown -R www-data:www-data /var/www/html"
pct exec $LXC_ID -- bash -c "ln -s /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/"
pct exec $LXC_ID -- bash -c "unlink /etc/nginx/sites-enabled/default"
pct exec $LXC_ID -- bash -c "systemctl restart nginx"
ip=$(pct exec $LXC_ID -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo "WordPress installation completed. Please navigate to http://$ip/index.php to finish the WordPress setup."
