#!/bin/bash

# Ask for the LXC container ID
read -p "Enter the LXC ID you want to use: " ctid

# Determine the Ubuntu 22.04 template name
template=$(pct template list | grep ubuntu-22.04 | cut -d' ' -f1)
if [ -z "$template" ]; then
    echo "Ubuntu 22.04 template not found. Please download it first."
    exit 1
fi

# Installation type choice
echo "Select installation type:"
echo "1) Fast Installation (Default settings: 25GB disk, 2GB RAM, 1 CPU Core, DHCP)"
echo "2) Customized Installation"
read -p "Enter your choice (1 or 2): " install_choice

case $install_choice in
    1)
        echo "Proceeding with Fast Installation..."
        disk_size="25G"  # Default disk size
        memory="2048"    # Default memory in MB
        cores="1"        # Default number of CPU cores
        net_mode="dhcp"  # Default network mode
        ;;
    2)
        echo "Proceeding with Customized Installation..."
        read -p "Enter disk size (e.g., 25G): " disk_size
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

# Create the LXC container
if [ "$net_mode" == "dhcp" ]; then
    pct create $ctid $template --hostname wordpress-container --cores $cores --memory $memory --net0 name=eth0,bridge=vmbr0,ip=dhcp
else
    pct create $ctid $template --hostname wordpress-container --cores $cores --memory $memory --net0 name=eth0,bridge=vmbr0,ip=$ipv4,gw=$gw
fi

# Start the container
pct start $ctid

# Allow some time for the network to come up
sleep 10

# Update and upgrade packages
pct exec $ctid -- apt-get update && apt-get upgrade -y

# Install Nginx, PHP, and MySQL
pct exec $ctid -- apt-get install nginx php-fpm php-mysql mysql-server -y

# Secure MySQL installation (You should automate or manually handle this part as it requires interactive inputs)
# pct exec $ctid -- mysql_secure_installation

# Create a WordPress database and user
pct exec $ctid -- mysql -e "CREATE DATABASE wordpress; CREATE USER 'wordpressuser'@'localhost' IDENTIFIED BY 'password'; GRANT ALL PRIVILEGES ON wordpress.* TO 'wordpressuser'@'localhost'; FLUSH PRIVILEGES;"

# Download and configure WordPress
pct exec $ctid -- bash -c "wget https://wordpress.org/latest.tar.gz -O /tmp/wordpress.tar.gz && tar xzf /tmp/wordpress.tar.gz -C /var/www/html --strip-components=1 && chown -R www-data:www-data /var/www/html"
pct exec $ctid -- bash -c "cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php"
pct exec $ctid -- bash -c "sed -i 's/database_name_here/wordpress/g' /var/www/html/wp-config.php"
pct exec $ctid -- bash -c "sed -i 's/username_here/wordpressuser/g' /var/www/html/wp-config.php"
pct exec $ctid -- bash -c "sed -i 's/password_here/password/g' /var/www/html/wp-config.php"

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
        fastcgi_pass unix:/run/php/php7.4-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}' > /etc/nginx/sites-available/wordpress"

pct exec $ctid -- bash -c "ln -s /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/"
pct exec $ctid -- bash -c "unlink /etc/nginx/sites-enabled/default"
pct exec $ctid -- bash -c "systemctl restart nginx"

echo "WordPress installation completed. Please navigate to your server IP to finish the WordPress setup. Remember to secure MySQL."
