#!/bin/bash

# Function to install necessary packages
install_packages() {
    sudo apt update && sudo apt upgrade -y
    sudo apt-get install -y git mc make htop build-essential speedtest-cli curl wget ncdu tmux psmisc net-tools
}

# Function to generate IPv6 addresses
generate_ipv6_addresses() {
    local prefix=$1
    local count=$2
    
    P_VALUES=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
    
    for ((i=1; i<=count; i++)); do
        a=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}
        b=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}
        c=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}
        d=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}
        
        echo "$prefix:$a:$b:$c:$d" >> ~/ip.list
    done
}

# Function to create ifaceup.sh and ifacedown.sh
create_iface_scripts() {
    local dev="he-ipv6"
    
    # Create ifaceup.sh
    echo "#!/bin/bash" > /app/proxy/ipv6-socks5-proxy/ifaceup.sh
    while read -r ip; do
        echo "ip -6 addr add $ip dev $dev" >> /app/proxy/ipv6-socks5-proxy/ifaceup.sh
    done < ~/ip.list
    chmod +x /app/proxy/ipv6-socks5-proxy/ifaceup.sh
    
    # Create ifacedown.sh
    echo "#!/bin/bash" > /app/proxy/ipv6-socks5-proxy/ifacedown.sh
    while read -r ip; do
        echo "ip -6 addr del $ip dev $dev" >> /app/proxy/ipv6-socks5-proxy/ifacedown.sh
    done < ~/ip.list
    chmod +x /app/proxy/ipv6-socks5-proxy/ifacedown.sh
}

# Function to configure network interface
configure_network() {
    local ipv6_prefix=$1
    local server_ipv4=$2
    local client_ipv4=$3
    
    cat << EOF | sudo tee -a /etc/network/interfaces
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
    address ${ipv6_prefix}::2
    netmask 64
    endpoint $server_ipv4
    local $client_ipv4
    ttl 255
    gateway ${ipv6_prefix}::1

up /app/proxy/ipv6-socks5-proxy/ifaceup.sh
down /app/proxy/ipv6-socks5-proxy/ifacedown.sh
EOF
}

# Function to modify kernel parameters
modify_kernel_parameters() {
    # Modify sysctl.conf
    echo "fs.file-max = 500000" | sudo tee -a /etc/sysctl.conf
    
    # Modify limits.conf
    cat << EOF | sudo tee -a /etc/security/limits.conf
* hard nofile 500000
* soft nofile 500000
root hard nofile 500000
root soft nofile 500000
* soft nproc 4000
* hard nproc 16000
root - memlock unlimited
EOF
    
    # Modify system.conf and user.conf
    for conf in /etc/systemd/system.conf /etc/systemd/user.conf; do
        cat << EOF | sudo tee -a $conf
DefaultLimitDATA=infinity
DefaultLimitSTACK=infinity
DefaultLimitCORE=infinity
DefaultLimitRSS=infinity
DefaultLimitNOFILE=102400
DefaultLimitAS=infinity
DefaultLimitNPROC=10240
DefaultLimitMEMLOCK=infinity
EOF
    done
}

# Function to install and configure 3proxy
install_3proxy() {
    cd /app/proxy/ipv6-socks5-proxy
    git clone https://github.com/z3APA3A/3proxy.git
    cd 3proxy
    ln -s Makefile.Linux Makefile
    echo "#define ANONYMOUS 1" > src/define.txt
    sed -i '31r src/define.txt' src/proxy.h
    make
    sudo make install
}

# Function to generate 3proxy configuration
generate_3proxy_config() {
    local user=$1
    local pass=$2
    local start_port=$3
    local count=$4
    local ipv4=$(hostname -I | awk '{print $1}')
    
    cat << EOF > /etc/3proxy/3proxy.cfg
daemon
maxconn 300
nserver [2606:4700:4700::1111]
nserver [2606:4700:4700::1001]
nserver [2001:4860:4860::8888]
nserver [2001:4860:4860::8844]
nscache 65536
nscache6 65536
timeouts 1 5 30 60 180 1800 15 60
stacksize 6000
flush
auth strong
users $user:CL:$pass
allow $user

EOF
    
    local port=$start_port
    while read -r ip; do
        echo "proxy -6 -s0 -n -a -p$port -i$ipv4 -e$ip" >> /etc/3proxy/3proxy.cfg
        echo "http://$user:$pass@$ipv4:$port" >> /app/proxy/ipv6-socks5-proxy/proxy_list.txt
        ((port++))
    done < ~/ip.list
}

# Main script
echo "IPv6 Proxy Setup Script"

# Install packages
install_packages

# Get user input
read -p "Enter your Routed /48 or /64 IPv6 prefix: " ipv6_prefix
read -p "Enter your Server IPv4 address: " server_ipv4
read -p "Enter your Client IPv4 address: " client_ipv4
read -p "Enter proxy login: " proxy_login
read -p "Enter proxy password: " proxy_password
read -p "Enter starting port number (default 1500): " start_port
start_port=${start_port:-1500}
read -p "Enter number of proxies to create (default 1): " proxy_count
proxy_count=${proxy_count:-1}

# Create necessary directories
sudo mkdir -p /app/proxy/ipv6-socks5-proxy
sudo chown -R $USER:$USER /app/proxy/ipv6-socks5-proxy

# Generate IPv6 addresses
generate_ipv6_addresses "$ipv6_prefix" "$proxy_count"

# Create interface scripts
create_iface_scripts

# Configure network
configure_network "$ipv6_prefix" "$server_ipv4" "$client_ipv4"

# Modify kernel parameters
modify_kernel_parameters

# Install 3proxy
install_3proxy

# Generate 3proxy configuration
generate_3proxy_config "$proxy_login" "$proxy_password" "$start_port" "$proxy_count"

# Restart networking and 3proxy
sudo systemctl restart networking
sudo systemctl restart 3proxy

echo "Setup complete. Proxy list is available at /app/proxy/ipv6-socks5-proxy/proxy_list.txt"
