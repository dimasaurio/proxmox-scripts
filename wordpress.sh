#!/bin/bash

# Check if LXC ID is set and is an integer
if [[ -z "$LXC_ID" || ! "$LXC_ID" =~ ^[0-9]+$ ]]; then
    echo "Error: LXC ID must be an integer."
    exit 1
fi

# Check if LXC container name is set
if [ -z "$LXC_NAME" ]; then
    echo "Error: LXC container name must be provided."
    exit 1
fi

# Check if root password is set
if [ -z "$ROOT_PASSWORD" ]; then
    echo "Error: Root password must be provided."
    exit 1
fi

# Check if WordPress database details are set
if [ -z "$WP_DBNAME" ] || [ -z "$WP_DBUSER" ] || [ -z "$WP_DBPASS" ]; then
    echo "Error: WordPress database details must be provided."
    exit 1
fi

# Check if installation type is set
if [ -z "$INSTALL_CHOICE" ]; then
    echo "Error: Installation choice must be provided."
    exit 1
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

# Installation type choice
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
        if [ -z "$DISK_SIZE" ] || [ -z "$MEMORY" ] || [ -z "$CORES" ] || [ -z "$NET_MODE" ]; then
            echo "Error: Customized installation parameters must be provided."
            exit 1
        fi
        disk_size="$DISK_SIZE"
        memory="$MEMORY"
        cores="$CORES"
        net_mode="$NET_MODE"
        if [ "$net_mode" == "static" ]; then
            if [ -z "$IPV4" ] || [ -z "$GW" ]; then
                echo "Error: IPv4 address and gateway must be provided for static network mode."
                exit 1
            fi
        fi
        ;;
    *)
        echo "Invalid choice. Exiting..."
        exit 1
        ;;
esac

# Create the LXC container with the specified name
if [ "$net_mode" == "dhcp" ]; then
    pct create $LXC_ID $template --hostname $LXC_NAME --password $ROOT_PASSWORD --cores $cores --memory $memory --rootfs local-lvm:${disk_size} --net0 name=eth0,bridge=vmbr0,ip=dhcp
else
    pct create $LXC_ID $template --hostname $LXC_NAME --password $ROOT_PASSWORD --cores $cores --memory $memory --rootfs local-lvm:${disk_size} --net0 name=eth0,bridge=vmbr0,ip=$IPV4,gw=$GW
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