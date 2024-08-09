#!/bin/bash

# Set up logging
exec > >(tee -a "/tmp/ipv6_proxy_setup.log") 2>&1

echo "Starting IPv6 proxy setup script at $(date)"

# Function to check command success
check_command() {
    if ! $@; then
        echo "Error: Failed to execute command: $@" >&2
        exit 1
    fi
}

# Prompt for necessary information
read -p "Enter your IPv6 prefix (e.g., 2a09:4c0:aee0:23d::): " IPV6_PREFIX
read -p "Enter the number of proxies to create: " PROXY_COUNT
read -p "Enter the starting port number: " START_PORT
read -p "Enter the IPv4 address of your server: " SERVER_IPV4

# Install necessary packages
echo "Installing required packages..."
check_command apt-get update
check_command apt-get install -y iptables-persistent 3proxy

# Set up IPv6 networking
echo "Configuring IPv6..."
check_command sysctl -w net.ipv6.conf.all.forwarding=1
check_command sysctl -w net.ipv6.conf.default.forwarding=1

# Configure ip6tables for NAT
echo "Configuring ip6tables..."
check_command ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
check_command ip6tables-save > /etc/iptables/rules.v6

# Generate IPv6 addresses and 3proxy config
echo "Generating proxy configurations..."
rm -f /etc/3proxy/3proxy.cfg
for i in $(seq 1 $PROXY_COUNT); do
    PORT=$((START_PORT + i - 1))
    IPV6="${IPV6_PREFIX}${i}"
    echo "proxy -6 -n -a -p$PORT -i$SERVER_IPV4 -e$IPV6" >> /etc/3proxy/3proxy.cfg
    ip -6 addr add $IPV6/64 dev eth0
done

# Start 3proxy
echo "Starting 3proxy..."
systemctl restart 3proxy

# Set up to run at boot
cat > /etc/systemd/system/ipv6-setup.service <<EOL
[Unit]
Description=IPv6 Proxy Setup
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ipv6-proxy-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL

cat > /usr/local/bin/ipv6-proxy-setup.sh <<EOL
#!/bin/bash
sysctl -w net.ipv6.conf.all.forwarding=1
sysctl -w net.ipv6.conf.default.forwarding=1
ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
systemctl restart 3proxy
EOL

chmod +x /usr/local/bin/ipv6-proxy-setup.sh
systemctl enable ipv6-setup.service

echo "IPv6 proxy setup complete. Rebooting system..."
reboot
