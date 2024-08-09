#!/bin/bash

# Function to check if a command was successful
check_command() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

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

# Get user input
echo "Enter your IPv6 prefix (e.g., 2a09:4c0:aee0:023d::/64):"
read IPV6_PREFIX
echo "Enter the number of IPs to generate:"
read IP_COUNT
echo "Enter the proxy start port (default: 20000):"
read -r PROXY_START_PORT
PROXY_START_PORT=${PROXY_START_PORT:-20000}
echo "Enter the proxy username:"
read PROXY_USER
echo "Enter the proxy password:"
read -s PROXY_PASS

# Validate and format IPv6 prefix
IPV6_PREFIX_EXPANDED=$(echo $IPV6_PREFIX | cut -d'/' -f1 | sed 's/://g' | sed 's/.\{4\}/&:/g' | sed 's/:$//')
IPV6_PREFIX_MASK=$(echo $IPV6_PREFIX | cut -d'/' -f2)

# Generate IPv6 addresses
echo "Generating IPv6 addresses..."
for i in $(seq 1 $IP_COUNT); do
    printf "%s:%04x:%04x:%04x:%04x\n" $IPV6_PREFIX_EXPANDED $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536))
done > ip.list

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
        address ${IPV6_PREFIX_EXPANDED}::2
        netmask ${IPV6_PREFIX_MASK}
        endpoint 185.181.60.47
        local 188.245.99.243
        ttl 255
        gateway ${IPV6_PREFIX_EXPANDED}::1

up /app/proxy/ipv6-socks5-proxy/ifaceup.sh
down /app/proxy/ipv6-socks5-proxy/ifacedown.sh
EOF

# Configure kernel parameters
echo "Configuring kernel parameters..."
sudo tee -a /etc/sysctl.conf << EOF
fs.file-max = 500000
EOF

sudo tee -a /etc/security/limits.conf << EOF
* hard nofile 500000
* soft nofile 500000
root hard nofile 500000
root soft nofile 500000
* soft nproc 4000
* hard nproc 16000
root - memlock unlimited
EOF

sudo tee -a /etc/systemd/system.conf << EOF
DefaultLimitDATA=infinity
DefaultLimitSTACK=infinity
DefaultLimitCORE=infinity
DefaultLimitRSS=infinity
DefaultLimitNOFILE=102400
DefaultLimitAS=infinity
DefaultLimitNPROC=10240
DefaultLimitMEMLOCK=infinity
EOF

sudo tee -a /etc/systemd/user.conf << EOF
DefaultLimitDATA=infinity
DefaultLimitSTACK=infinity
DefaultLimitCORE=infinity
DefaultLimitRSS=infinity
DefaultLimitNOFILE=102400
DefaultLimitAS=infinity
DefaultLimitNPROC=10240
DefaultLimitMEMLOCK=infinity
EOF

# Install and configure 3proxy
echo "Installing and configuring 3proxy..."
git clone https://github.com/z3APA3A/3proxy.git
cd 3proxy
ln -s Makefile.Linux Makefile
touch src/define.txt
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
nserver [2606:4700:4700::1111]
nserver [2606:4700:4700::1001]
nserver [2001:4860:4860::8888]
nserver [2001:4860:4860::8844]
nserver [2a02:6b8::feed:0ff]
nserver [2a02:6b8:0:1::feed:0ff]
nscache 65536
nscache6 65536
timeouts 1 5 30 60 180 1800 15 60
stacksize 6000
flush
auth strong
users $PROXY_USER:CL:$PROXY_PASS
allow $PROXY_USER

EOF

PROXY_PORT=$PROXY_START_PORT
while read -r ip; do
    echo "proxy -6 -s0 -n -a -olSO_REUSEADDR,SO_REUSEPORT -ocTCP_TIMESTAMPS,TCP_NODELAY -osTCP_NODELAY,SO_KEEPALIVE -p$PROXY_PORT -i$IPV4 -e$ip" >> /etc/3proxy/3proxy.cfg
    echo "$IPV4:$PROXY_PORT@$PROXY_USER:$PROXY_PASS;v6;http" >> proxylist_key_collector.txt
    echo "http://$PROXY_USER:$PROXY_PASS@$IPV4:$PROXY_PORT" >> xevil.txt
    ((PROXY_PORT++))
done < ip.list

# Restart services
echo "Restarting services..."
sudo systemctl daemon-reload
sudo systemctl restart networking
sudo systemctl restart 3proxy

echo "Setup complete. Please reboot your system to apply all changes."
echo "After reboot, your proxies will be available. You can find the proxy lists in:"
echo "- /app/proxy/ipv6-socks5-proxy/proxylist_key_collector.txt"
echo "- /app/proxy/ipv6-socks5-proxy/xevil.txt"
