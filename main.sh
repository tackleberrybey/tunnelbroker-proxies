#!/bin/bash

# Set up logging
exec > >(tee -a "/tmp/proxy_setup.log") 2>&1

echo "Starting proxy setup script at $(date)"

# Function to check command success
check_command() {
    if ! $@; then
        echo "Error: Failed to execute command: $@" >&2
        exit 1
    fi
}

# Prompt for necessary information
echo "↓ Routed /64 IPv6 prefix from tunnelbroker (*:*:*::/64):"
read PROXY_NETWORK

echo "↓ Server IPv4 address from tunnelbroker:"
read TUNNEL_IPV4_ADDR

echo "↓ Proxies login (can be blank):"
read PROXY_LOGIN

if [[ "$PROXY_LOGIN" ]]; then
  echo "↓ Proxies password:"
  read PROXY_PASS
fi

echo "↓ Port numbering start (default 1500):"
read PROXY_START_PORT
PROXY_START_PORT=${PROXY_START_PORT:-1500}

echo "↓ Proxies count (default 1):"
read PROXY_COUNT
PROXY_COUNT=${PROXY_COUNT:-1}

echo "↓ Proxies protocol (http, socks5; default http):"
read PROXY_PROTOCOL
PROXY_PROTOCOL=${PROXY_PROTOCOL:-http}

# Install necessary packages
echo "Installing necessary packages..."
check_command apt-get update
check_command apt-get install -y iptables-persistent build-essential wget

# Compile and install 3proxy
echo "Compiling and installing 3proxy..."
cd /tmp
check_command wget https://github.com/z3APA3A/3proxy/archive/0.9.3.tar.gz
check_command tar xzf 0.9.3.tar.gz
cd 3proxy-0.9.3
check_command make -f Makefile.Linux
check_command make -f Makefile.Linux install
cd ..
rm -rf 3proxy-0.9.3 0.9.3.tar.gz

# Set up IPv6 tunnel
echo "Setting up IPv6 tunnel..."
HOST_IPV4_ADDR=$(hostname -I | awk '{print $1}')
check_command ip tunnel add he-ipv6 mode sit remote $TUNNEL_IPV4_ADDR local $HOST_IPV4_ADDR ttl 255
check_command ip link set he-ipv6 up
check_command ip addr add ${PROXY_NETWORK}::2/64 dev he-ipv6
check_command ip -6 route add default via ${PROXY_NETWORK}::1 dev he-ipv6

# Enable IPv6 forwarding
echo "Enabling IPv6 forwarding..."
echo "net.ipv6.conf.all.forwarding=1" > /etc/sysctl.d/60-ipv6-forward.conf
check_command sysctl -p /etc/sysctl.d/60-ipv6-forward.conf

# Set up iptables rules
echo "Setting up iptables rules..."
check_command ip6tables -t nat -A POSTROUTING -o he-ipv6 -j MASQUERADE
check_command ip6tables-save > /etc/iptables/rules.v6

# Create 3proxy configuration
echo "Creating 3proxy configuration..."
cat > /etc/3proxy/3proxy.cfg <<EOL
daemon
maxconn 1000
nserver 1.1.1.1
nserver 8.8.8.8
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6291456
flush
auth none
EOL

for ((i=0; i<$PROXY_COUNT; i++)); do
    PORT=$((PROXY_START_PORT + i))
    echo "$PROXY_PROTOCOL -6 -n -a -p$PORT -i${PROXY_NETWORK}::2 -e${PROXY_NETWORK}::$((i+3))" >> /etc/3proxy/3proxy.cfg
done

# Create systemd service for 3proxy
echo "Creating systemd service for 3proxy..."
cat > /etc/systemd/system/3proxy.service <<EOL
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always

[Install]
WantedBy=multi-user.target
EOL

# Enable and start the service
echo "Enabling and starting 3proxy service..."
check_command systemctl daemon-reload
check_command systemctl enable 3proxy
check_command systemctl start 3proxy

echo "Setup completed successfully. Your IPv6 proxies should now be running."
echo "Proxy addresses:"
for ((i=0; i<$PROXY_COUNT; i++)); do
    PORT=$((PROXY_START_PORT + i))
    echo "[${PROXY_NETWORK}::$((i+3))]:$PORT"
done
