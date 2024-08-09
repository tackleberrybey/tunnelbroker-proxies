#!/bin/bash

# Function to get user input
get_input() {
    read -p "$1: " value
    echo $value
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check and install necessary packages
install_packages() {
    if ! command_exists git || ! command_exists make; then
        echo "Installing necessary packages..."
        sudo apt-get update
        sudo apt-get install -y git make build-essential
    fi
}

# Get user inputs
ipv6_prefix=$(get_input "Enter your Routed /48 or /64 IPv6 prefix from tunnelbroker")
server_ipv4=$(get_input "Enter your Server IPv4 address from tunnelbroker")
proxy_login=$(get_input "Enter proxy login")
proxy_password=$(get_input "Enter proxy password")
port_start=$(get_input "Enter port numbering start (default 1500)")
port_start=${port_start:-1500}
proxy_count=$(get_input "Enter number of proxies to create (default 1)")
proxy_count=${proxy_count:-1}

# Install necessary packages
install_packages

# Create necessary directories
sudo mkdir -p /app/proxy/ipv6-socks5-proxy
sudo chown -R $USER:$USER /app/proxy/ipv6-socks5-proxy
cd /app/proxy/ipv6-socks5-proxy

# Generate IPv6 addresses
echo ">-- Generating IPv6 addresses"
touch ip.list

P_VALUES=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
PROXY_GENERATING_INDEX=1

generate_proxy() {
  a=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}
  b=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}
  c=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}
  d=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}
  e=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}

  echo "$ipv6_prefix:$a:$b:$c:$d:$e" >> ip.list
}

while [ "$PROXY_GENERATING_INDEX" -le $proxy_count ]; do
  generate_proxy
  let "PROXY_GENERATING_INDEX+=1"
done

# Create ifaceup.sh
echo "#!/bin/bash" > ifaceup.sh
while read -r ip; do
    echo "ip -6 addr add $ip dev he-ipv6" >> ifaceup.sh
done < ip.list
chmod +x ifaceup.sh

# Create ifacedown.sh
echo "#!/bin/bash" > ifacedown.sh
while read -r ip; do
    echo "ip -6 addr del $ip dev he-ipv6" >> ifacedown.sh
done < ip.list
chmod +x ifacedown.sh

# Configure network interface
sudo tee /etc/network/interfaces << EOF
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
        address ${ipv6_prefix}::2
        netmask 64
        endpoint $server_ipv4
        local $(hostname -I | awk '{print $1}')
        ttl 255
        gateway ${ipv6_prefix}::1

up /app/proxy/ipv6-socks5-proxy/ifaceup.sh
down /app/proxy/ipv6-socks5-proxy/ifacedown.sh
EOF

# Configure kernel parameters
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

sudo tee -a /etc/sysctl.conf << EOF
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_syncookies = 1
EOF

sudo tee -a /etc/systemd/system.conf /etc/systemd/user.conf << EOF
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
cd /app/proxy/ipv6-socks5-proxy
if [ ! -d "3proxy" ]; then
    git clone https://github.com/z3APA3A/3proxy.git
fi
cd 3proxy
ln -sf Makefile.Linux Makefile
echo "#define ANONYMOUS 1" > src/define.txt
sed -i '31r src/define.txt' src/proxy.h
make
sudo make install

# Create 3proxy configuration directory if it doesn't exist
sudo mkdir -p /etc/3proxy

# Create 3proxy configuration
sudo tee /etc/3proxy/3proxy.cfg << EOF
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
users $proxy_login:CL:$proxy_password
allow $proxy_login

EOF

# Add proxy entries to 3proxy configuration
current_port=$port_start
while read -r ip; do
    echo "proxy -6 -s0 -n -a -olSO_REUSEADDR,SO_REUSEPORT -ocTCP_TIMESTAMPS,TCP_NODELAY -osTCP_NODELAY,SO_KEEPALIVE -p$current_port -i$server_ipv4 -e$ip" | sudo tee -a /etc/3proxy/3proxy.cfg
    echo "http://$proxy_login:$proxy_password@$server_ipv4:$current_port" >> proxies.txt
    ((current_port++))
done < ip.list

# Create systemd service file for 3proxy
sudo tee /etc/systemd/system/3proxy.service << EOF
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start 3proxy service
sudo systemctl daemon-reload
sudo systemctl enable 3proxy
sudo systemctl start 3proxy

echo "Setup complete. Proxy list saved in proxies.txt"
echo "Please reboot your system for all changes to take effect."
