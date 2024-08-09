#!/bin/bash

# Function to check if command executed successfully
check_command() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

# Update and install dependencies
apt update && apt upgrade -y
check_command "Failed to update and upgrade system"

apt-get install -y git mc make htop build-essential speedtest-cli curl wget ncdu tmux psmisc net-tools
check_command "Failed to install dependencies"

# Create directory for proxy files
mkdir -p /app/proxy/ipv6-socks5-proxy
chown -R $USER:$USER /app/proxy/ipv6-socks5-proxy
cd /app/proxy/ipv6-socks5-proxy

# Get user input for IPv6 subnet and other details
read -p "Enter your IPv6 subnet (e.g., 2a09:4c0:aee0:023d::/64): " IPV6_SUBNET
read -p "Enter the number of proxies to generate: " PROXY_COUNT
read -p "Enter proxy username: " PROXY_USER
read -p "Enter proxy password: " PROXY_PASS
read -p "Enter starting port for proxies (default 20000): " PROXY_START_PORT
PROXY_START_PORT=${PROXY_START_PORT:-20000}

# Generate IPv6 addresses
echo "Generating IPv6 addresses..."
for i in $(seq 1 $PROXY_COUNT); do
    printf "%s:%04x:%04x:%04x:%04x\n" $IPV6_SUBNET $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) >> ip.list
done

# Create ifaceup.sh
echo "Creating ifaceup.sh..."
echo "#!/bin/bash" > ifaceup.sh
while read -r ip; do
    echo "ip -6 addr add $ip dev he-ipv6" >> ifaceup.sh
done < ip.list
chmod +x ifaceup.sh

# Create ifacedown.sh
echo "Creating ifacedown.sh..."
echo "#!/bin/bash" > ifacedown.sh
while read -r ip; do
    echo "ip -6 addr del $ip dev he-ipv6" >> ifacedown.sh
done < ip.list
chmod +x ifacedown.sh

# Configure network interface
echo "Configuring network interface..."
cat << EOF | sudo tee -a /etc/network/interfaces
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
        address ${IPV6_SUBNET%::*}::2
        netmask 64
        endpoint 185.181.60.47
        local 188.245.99.243
        ttl 255
        gateway ${IPV6_SUBNET%::*}::1

up /app/proxy/ipv6-socks5-proxy/ifaceup.sh
down /app/proxy/ipv6-socks5-proxy/ifacedown.sh
EOF

# Configure sysctl
echo "Configuring sysctl..."
cat << EOF | sudo tee -a /etc/sysctl.conf
fs.file-max = 500000
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 3
EOF

# Configure limits
echo "Configuring limits..."
cat << EOF | sudo tee -a /etc/security/limits.conf
* hard nofile 500000
* soft nofile 500000
root hard nofile 500000
root soft nofile 500000
* soft nproc 4000
* hard nproc 16000
root - memlock unlimited
EOF

# Configure systemd
echo "Configuring systemd..."
for file in /etc/systemd/system.conf /etc/systemd/user.conf; do
    cat << EOF | sudo tee -a $file
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

# Add IPv6 DNS to resolv.conf
echo "Adding IPv6 DNS..."
cat << EOF | sudo tee -a /etc/resolv.conf
nameserver 2606:4700:4700::1111
nameserver 2606:4700:4700::1001
nameserver 2001:4860:4860::8888
nameserver 2001:4860:4860::8844
nameserver 2a02:6b8::feed:0ff
nameserver 2a02:6b8:0:1::feed:0ff
EOF

# Install and configure 3proxy
echo "Installing and configuring 3proxy..."
git clone https://github.com/z3APA3A/3proxy.git
cd 3proxy
ln -s Makefile.Linux Makefile
echo "#define ANONYMOUS 1" > src/define.txt
sed -i '31r src/define.txt' src/proxy.h
make
sudo make install
cd ..

# Create 3proxy configuration
echo "Creating 3proxy configuration..."
IPV4=$(hostname -I | awk '{print $1}')
cat << EOF > /etc/3proxy/3proxy.cfg
daemon
maxconn 300
nserver 2606:4700:4700::1111
nserver 2606:4700:4700::1001
nserver 2001:4860:4860::8888
nserver 2001:4860:4860::8844
nserver 2a02:6b8::feed:0ff
nserver 2a02:6b8:0:1::feed:0ff
nscache 65536
nscache6 65536
timeouts 1 5 30 60 180 1800 15 60
stacksize 6000
flush
auth strong
users $PROXY_USER:CL:$PROXY_PASS
allow $PROXY_USER

EOF

PORT=$PROXY_START_PORT
while read -r ip; do
    echo "proxy -6 -s0 -n -a -olSO_REUSEADDR,SO_REUSEPORT -ocTCP_TIMESTAMPS,TCP_NODELAY -osTCP_NODELAY,SO_KEEPALIVE -p$PORT -i$IPV4 -e$ip" >> /etc/3proxy/3proxy.cfg
    echo "$IPV4:$PORT@$PROXY_USER:$PROXY_PASS;v6;http" >> proxylist_key_collector.txt
    echo "http://$PROXY_USER:$PROXY_PASS@$IPV4:$PORT" >> xevil.txt
    ((PORT++))
done < ip.list

# Restart networking and 3proxy
echo "Restarting networking and 3proxy..."
sudo systemctl restart networking
sudo systemctl restart 3proxy

echo "Setup complete. Proxies are ready to use."
echo "Proxy list for Key Collector: proxylist_key_collector.txt"
echo "Proxy list for XEvil: xevil.txt"
