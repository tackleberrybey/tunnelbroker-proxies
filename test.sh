#!/bin/bash

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root" 
  exit 1
fi

# Function to generate a random hex character
random_hex() {
  echo "0 1 2 3 4 5 6 7 8 9 a b c d e f" | tr ' ' '\n' | shuf | head -n 1
}

# Function to generate a single IPv6 address
generate_ipv6() {
  local prefix="$1"
  local a=$(random_hex)$(random_hex)$(random_hex)$(random_hex)
  local b=$(random_hex)$(random_hex)$(random_hex)$(random_hex)
  local c=$(random_hex)$(random_hex)$(random_hex)$(random_hex)
  local d=$(random_hex)$(random_hex)$(random_hex)$(random_hex)
  local e=$(random_hex)$(random_hex)$(random_hex)$(random_hex)
  echo "${prefix}:${a}:${b}:${c}:${d}:${e}"
}

# --- User Input ---

# Read routed /64 IPv6 prefix
read -p "Enter your routed /64 IPv6 prefix (e.g., 2a09:04c0:aee0:023d::/64): " PROXY_NETWORK

# Validate IPv6 prefix format
if [[ ! $PROXY_NETWORK =~ ^([0-9a-f]{1,4}:){7}[0-9a-f]{1,4}/64$ ]]; then
  echo "Invalid IPv6 prefix format: $PROXY_NETWORK"
  exit 1
fi

# Read server IPv4 address
read -p "Enter your server's IPv4 address: " TUNNEL_IPV4_ADDR

# Validate IPv4 address format
if [[ ! $TUNNEL_IPV4_ADDR =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Invalid IPv4 address format: $TUNNEL_IPV4_ADDR"
  exit 1
fi

# Read proxy login (optional)
read -p "Enter proxy login (leave blank for none): " PROXY_LOGIN
if [[ -n "$PROXY_LOGIN" ]]; then
  read -s -p "Enter proxy password: " PROXY_PASS
  echo
fi

# Read proxy start port (default: 1500)
read -p "Enter proxy start port (default: 1500): " PROXY_START_PORT
PROXY_START_PORT=${PROXY_START_PORT:-1500}

# Read proxy count (default: 1)
read -p "Enter proxy count (default: 1): " PROXY_COUNT
PROXY_COUNT=${PROXY_COUNT:-1}

# Read proxy protocol (default: http)
read -p "Enter proxy protocol (http/socks5, default: http): " PROXY_PROTOCOL
PROXY_PROTOCOL=${PROXY_PROTOCOL:-http}

# --- Script Execution ---

# Update packages and install dependencies
apt-get update > /dev/null 2>&1
apt-get -y install gcc g++ make bc pwgen git > /dev/null 2>&1

# --- Network Configuration ---

# Extract network address from prefix
NETWORK_ADDRESS=$(echo $PROXY_NETWORK | cut -d/ -f1)

# Generate IPv6 addresses and add them to the interface configuration
echo "Generating IPv6 addresses..."
for (( i=0; i<$PROXY_COUNT; i++ )); do
  IP_ADDRESS=$(generate_ipv6 $NETWORK_ADDRESS)
  echo "ip -6 addr add $IP_ADDRESS/64 dev he-ipv6" >> /app/proxy/ipv6-socks5-proxy/ifaceup.sh
  echo "ip -6 addr del $IP_ADDRESS/64 dev he-ipv6" >> /app/proxy/ipv6-socks5-proxy/ifacedown.sh
done

# --- 3proxy Configuration ---

# Create directories
mkdir -p /app/proxy/ipv6-socks5-proxy
cd /app/proxy/ipv6-socks5-proxy

# Download and install 3proxy
git clone https://github.com/z3APA3A/3proxy.git
cd 3proxy
ln -s Makefile.Linux Makefile
touch src/define.txt
echo "#define ANONYMOUS 1" > src/define.txt
sed -i '31r src/define.txt' src/proxy.h
make
make install

# Configure 3proxy
cat > /etc/3proxy/3proxy.cfg <<EOF
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
EOF

# Add authentication to 3proxy config
if [[ -n "$PROXY_LOGIN" ]]; then
  echo "auth strong" >> /etc/3proxy/3proxy.cfg
  echo "users $PROXY_LOGIN:CL:$PROXY_PASS" >> /etc/3proxy/3proxy.cfg
  echo "allow $PROXY_LOGIN" >> /etc/3proxy/3proxy.cfg
else
  echo "auth none" >> /etc/3proxy/3proxy.cfg
fi

# Generate proxy entries in 3proxy config
CURRENT_PORT=$PROXY_START_PORT
for (( i=0; i<$PROXY_COUNT; i++ )); do
  IP_ADDRESS=$(sed -n "$((i+1))p" /app/proxy/ipv6-socks5-proxy/ifaceup.sh | awk '{print $3}')
  echo "proxy -6 -s0 -n -a -olSO_REUSEADDR,SO_REUSEPORT -ocTCP_TIMESTAMPS,TCP_NODELAY -osTCP_NODELAY,SO_KEEPALIVE -p$CURRENT_PORT -i$TUNNEL_IPV4_ADDR -e$IP_ADDRESS" >> /etc/3proxy/3proxy.cfg
  echo "$PROXY_PROTOCOL://$( [ -n "$PROXY_LOGIN" ] && echo "$PROXY_LOGIN:$PROXY_PASS@" || echo "" )"$TUNNEL_IPV4_ADDR:$CURRENT_PORT" >> /app/proxy/ipv6-socks5-proxy/proxylist.txt
  CURRENT_PORT=$((CURRENT_PORT + 1))
done

# --- System Configuration ---

# Modify kernel parameters
cat >> /etc/sysctl.conf <<EOF
fs.file-max = 500000
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_syncookies = 1
EOF

# Modify system limits
cat >> /etc/security/limits.conf <<EOF
* hard nofile 500000
* soft nofile 500000
root hard nofile 500000
root soft nofile 500000
* soft nproc 4000
* hard nproc 16000
root - memlock unlimited
EOF

# Modify systemd configuration files
cat >> /etc/systemd/system.conf <<EOF
DefaultLimitDATA=infinity
DefaultLimitSTACK=infinity
DefaultLimitCORE=infinity
DefaultLimitRSS=infinity
DefaultLimitNOFILE=102400
DefaultLimitAS=infinity
DefaultLimitNPROC=10240
DefaultLimitMEMLOCK=infinity
EOF

cat >> /etc/systemd/user.conf <<EOF
DefaultLimitDATA=infinity
DefaultLimitSTACK=infinity
DefaultLimitCORE=infinity
DefaultLimitRSS=infinity
DefaultLimitNOFILE=102400
DefaultLimitAS=infinity
DefaultLimitNPROC=10240
DefaultLimitMEMLOCK=infinity
EOF

# Add IPv6 DNS servers to resolv.conf
cat >> /etc/resolv.conf <<EOF
nameserver 2606:4700:4700::1111
nameserver 2606:4700:4700::1001
nameserver 2001:4860:4860::8888
nameserver 2001:4860:4860::8844
nameserver 2a02:6b8::feed:0ff
nameserver 2a02:6b8:0:1::feed:0ff
EOF

# --- Interface Configuration ---

# Configure he-ipv6 interface
cat > /etc/network/interfaces.d/he-ipv6.cfg <<EOF
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
  address $NETWORK_ADDRESS
  netmask 64
  endpoint $TUNNEL_IPV4_ADDR
  local $(hostname -I | awk '{print $1}')
  ttl 255
  up /app/proxy/ipv6-socks5-proxy/ifaceup.sh
  down /app/proxy/ipv6-socks5-proxy/ifacedown.sh
EOF

# Make scripts executable
chmod +x /app/proxy/ipv6-socks5-proxy/ifaceup.sh
chmod +x /app/proxy/ipv6-socks5-proxy/ifacedown.sh

# Restart networking and 3proxy
systemctl restart networking
systemctl enable 3proxy.service
systemctl restart 3proxy.service

echo "IPv6 proxy setup complete!"
echo "Your proxy list is saved to: /app/proxy/ipv6-socks5-proxy/proxylist.txt"
