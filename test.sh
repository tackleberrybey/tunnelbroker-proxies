#!/bin/bash

# Function to check if command was successful
check_command() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

# Prompt for necessary information
read -p "Enter your IPv6 prefix (e.g., 2a09:04c0:aee0:023d::/64): " PROXY_NETWORK
read -p "Enter the number of proxies to generate: " PROXY_COUNT
read -p "Enter proxy username: " PROXY_USER
read -s -p "Enter proxy password: " PROXY_PASS
echo
read -p "Enter the starting port number for proxies (default: 20000): " PROXY_START_PORT
PROXY_START_PORT=${PROXY_START_PORT:-20000}

# Validate inputs
if [[ ! $PROXY_NETWORK =~ ^[0-9a-fA-F:]+/[0-9]+$ ]]; then
    echo "Invalid IPv6 prefix format."
    exit 1
fi

if ! [[ "$PROXY_COUNT" =~ ^[0-9]+$ ]] || [ "$PROXY_COUNT" -le 0 ]; then
    echo "Invalid number of proxies."
    exit 1
fi

if [ -z "$PROXY_USER" ] || [ -z "$PROXY_PASS" ]; then
    echo "Username and password cannot be empty."
    exit 1
fi

# Update and install dependencies
echo "Updating and installing dependencies..."
sudo apt update && sudo apt upgrade -y
sudo apt-get install -y git mc make htop build-essential speedtest-cli curl wget ncdu tmux psmisc net-tools
check_command "Failed to install dependencies"

# Create directory structure
echo "Creating directory structure..."
sudo mkdir -p /app/proxy/ipv6-socks5-proxy
sudo chown -R $USER:$USER /app/proxy/ipv6-socks5-proxy
cd /app/proxy/ipv6-socks5-proxy

# Generate IPv6 addresses
echo "Generating IPv6 addresses..."
generate_ipv6() {
    printf "%s%04x:%04x:%04x:%04x\n" "$1" $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
}

for i in $(seq 1 $PROXY_COUNT); do
    generate_ipv6 "${PROXY_NETWORK%::*}::" >> ip.list
done

# Create ifaceup.sh and ifacedown.sh
echo "Creating interface scripts..."
for ip in $(cat ip.list); do
    echo "ip -6 addr add $ip dev sbtb-ipv6" >> ifaceup.sh
    echo "ip -6 addr del $ip dev sbtb-ipv6" >> ifacedown.sh
done
chmod +x ifaceup.sh ifacedown.sh

# Configure network interface
echo "Configuring network interface..."
cat << EOF | sudo tee /etc/network/interfaces.d/sbtb-ipv6
auto sbtb-ipv6
iface sbtb-ipv6 inet6 v4tunnel
    address 2a09:4c0:aee0:227::2/64
    endpoint 185.181.60.47
    local 188.245.99.243
    ttl 255
    gateway 2a09:4c0:aee0:227::1

up /app/proxy/ipv6-socks5-proxy/ifaceup.sh
down /app/proxy/ipv6-socks5-proxy/ifacedown.sh
EOF

# Configure kernel parameters
echo "Configuring kernel parameters..."
cat << EOF | sudo tee -a /etc/sysctl.conf
fs.file-max = 500000
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
EOF

sudo sysctl -p

# Configure system limits
echo "Configuring system limits..."
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
for conf in /etc/systemd/system.conf /etc/systemd/user.conf; do
    sudo tee -a $conf << EOF
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

# Add IPv6 DNS servers
echo "Adding IPv6 DNS servers..."
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
cd /app/proxy/ipv6-socks5-proxy
git clone https://github.com/z3APA3A/3proxy.git
cd 3proxy
ln -s Makefile.Linux Makefile
echo "#define ANONYMOUS 1" > src/define.txt
sed -i '31r src/define.txt' src/proxy.h
make
sudo make install
check_command "Failed to install 3proxy"

# Create 3proxy configuration script
echo "Creating 3proxy configuration script..."
cat << EOF > /app/proxy/ipv6-socks5-proxy/genproxy.sh
#!/bin/bash

ipv4=\$(hostname -I | awk '{print \$1}')
portproxy=$PROXY_START_PORT
user=$PROXY_USER
pass=$PROXY_PASS
config="/etc/3proxy/3proxy.cfg"

echo -ne > \$config
echo -ne > /app/proxy/ipv6-socks5-proxy/proxylist.txt

cat << EOC >> \$config
daemon
maxconn 300
nserver 2606:4700:4700::1111
nserver 2606:4700:4700::1001
nscache 65536
nscache6 65536
timeouts 1 5 30 60 180 1800 15 60
stacksize 6000
flush
auth strong
users \$user:CL:\$pass
allow \$user
EOC

for i in \$(cat /app/proxy/ipv6-socks5-proxy/ip.list); do
    echo "proxy -6 -s0 -n -a -p\$portproxy -i\$ipv4 -e\$i" >> \$config
    echo "http://\$user:\$pass@\$ipv4:\$portproxy" >> /app/proxy/ipv6-socks5-proxy/proxylist.txt
    ((portproxy++))
done
EOF

chmod +x /app/proxy/ipv6-socks5-proxy/genproxy.sh

# Generate 3proxy configuration
echo "Generating 3proxy configuration..."
/app/proxy/ipv6-socks5-proxy/genproxy.sh

# Restart networking and 3proxy
echo "Restarting networking and 3proxy..."
sudo systemctl restart networking
sudo systemctl restart 3proxy

echo "Setup completed successfully. Please reboot your system to apply all changes."
