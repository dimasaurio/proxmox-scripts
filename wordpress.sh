#!/bin/bash

# Prompt for the LXC container ID
read -p "Enter the LXC ID you want to use: " ctid
if ! [[ "$ctid" =~ ^[0-9]+$ ]]; then
    echo "Error: LXC ID must be an integer."
    exit 1
fi

# Prompt for the LXC container name
read -p "Enter the name for the LXC container: " ctname

while true; do
    read -s -p "Enter the root password for the LXC container: " root_password
    echo
    read -s -p "Confirm the root password: " confirm_password
    echo
    if [ "$root_password" == "$confirm_password" ]; then
        echo "Password confirmed."
        break
    else
        echo "Passwords do not match. Please try again."
    fi
done

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

# Prompt for database credentials
read -p "Enter the WordPress database name: " wp_dbname
read -p "Enter the WordPress database username: " wp_dbuser
read -s -p "Enter the WordPress database password: " wp_dbpass
echo

# Installation type choice
echo "Select installation type:"
echo "1) Fast Installation (Default settings: 25GB disk, 2GB RAM, 1 CPU Core, DHCP)"
echo "2) Customized Installation"
read -p "Enter your choice (1 or 2): " install_choice

case $install_choice in
    1)
        echo "Proceeding with Fast Installation..."
        disk_size="25"  # Default disk size
        memory="2048"    # Default memory in MB
        cores="1"        # Default number of CPU cores
        net_mode="dhcp"  # Default network mode
        ;;
    2)
        echo "Proceeding with Customized Installation..."
        read -p "Enter disk size in G(e.g., 25): " disk_size
        read -p "Enter memory size in MB (e.g., 2048): " memory
        read -p "Enter number of CPU cores (e.g., 1): " cores
        read -p "Enter network mode (dhcp or static): " net_mode
        if [ "$net_mode" == "static" ]; then
            read -p "Enter IPv4 address (e.g., 192.168.1.100/24): " ipv4
            read -p "Enter gateway (e.g., 192.168.1.1): " gw
        fi
        ;;
    *)
        echo "Invalid choice. Exiting..."
        exit 1
        ;;
esac

# Create the LXC container with the specified name
if [ "$net_mode" == "dhcp" ]; then
    pct create $ctid $template --hostname $ctname --password $root_password --cores $cores --memory $memory --rootfs local-lvm:${disk_size} --net0 name=eth0,bridge=vmbr0,ip=dhcp
else
    pct create $ctid $template --hostname $ctname --password $root_password --cores $cores --memory $memory --rootfs local-lvm:${disk_size} --net0 name=eth0,bridge=vmbr0,ip=$ipv4,gw=$gw
fi

# Start the container
pct start $ctid

# Allow some time for the network to come up
sleep 10

# Update and upgrade packages
pct exec $ctid -- apt-get update && apt-get upgrade -y

# Install Nginx, PHP, and MySQL
pct exec $ctid -- apt-get install nginx php-fpm php-mysql mysql-server -y

# Create a WordPress database and user with the provided credentials
pct exec $ctid -- mysql -e "CREATE DATABASE ${wp_dbname}; CREATE USER '${wp_dbuser}'@'localhost' IDENTIFIED BY '${wp_dbpass}'; GRANT ALL PRIVILEGES ON ${wp_dbname}.* TO '${wp_dbuser}'@'localhost'; FLUSH PRIVILEGES;"

# Download and configure WordPress
pct exec $ctid -- bash -c "wget https://wordpress.org/latest.tar.gz -O /tmp/wordpress.tar.gz && tar xzf /tmp/wordpress.tar.gz -C /var/www/html --strip-components=1 && chown -R www-data:www-data /var/www/html"
pct exec $ctid -- bash -c "cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php"
pct exec $ctid -- bash -c "sed -i 's/database_name_here/${wp_dbname}/g' /var/www/html/wp-config.php"
pct exec $ctid -- bash -c "sed -i 's/username_here/${wp_dbuser}/g' /var/www/html/wp-config.php"
pct exec $ctid -- bash -c "sed -i 's/password_here/${wp_dbpass}/g' /var/www/html/wp-config.php"

# Configure Nginx for WordPress
pct exec $ctid -- bash -c "echo 'server {
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

pct exec $ctid -- bash -c "chown -R www-data:www-data /var/www/html"
pct exec $ctid -- bash -c "ln -s /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/"
pct exec $ctid -- bash -c "unlink /etc/nginx/sites-enabled/default"
pct exec $ctid -- bash -c "systemctl restart nginx"
ip=$(pct exec $ctid -- ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

echo "WordPress installation completed. Please navigate to http://$ip/index.php to finish the WordPress setup."