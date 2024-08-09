#!/bin/bash

# Function to get user input with default value
get_input() {
    local prompt="$1"
    local default="$2"
    local input
    read -p "$prompt [$default]: " input
    echo "${input:-$default}"
}

# Get user inputs
ipv6_prefix=$(get_input "Enter Routed /48 or /64 IPv6 prefix from tunnelbroker" "2a09:4c0:aee0:023d::/64")
server_ipv4=$(get_input "Enter Server IPv4 address from tunnelbroker" "185.181.60.47")
proxy_login=$(get_input "Enter Proxies login" "user")
port_start=$(get_input "Enter Port numbering start" "1500")
proxy_count=$(get_input "Enter Proxies count" "1")
proxy_protocol=$(get_input "Enter Proxies protocol (http, socks5)" "http")

# Create necessary directories
sudo mkdir -p /app/proxy/ipv6-socks5-proxy
sudo chown -R $USER:$USER /app/proxy/ipv6-socks5-proxy
cd /app/proxy/ipv6-socks5-proxy

# Generate IPv6 addresses
echo "Generating IPv6 addresses..."
# This part would typically use an external tool or script to generate IPv6 addresses
# For this example, we'll just create a dummy list
for i in $(seq 1 $proxy_count); do
    echo "${ipv6_prefix%::*}::$i" >> ip.list
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

# Update /etc/network/interfaces
echo "Updating /etc/network/interfaces..."
cat << EOF | sudo tee -a /etc/network/interfaces
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
        address ${ipv6_prefix%::*}::2
        netmask ${ipv6_prefix##*/}
        endpoint $server_ipv4
        local $(hostname -I | awk '{print $1}')
        ttl 255
        gateway ${ipv6_prefix%::*}::1

up /app/proxy/ipv6-socks5-proxy/ifaceup.sh
down /app/proxy/ipv6-socks5-proxy/ifacedown.sh
EOF

# Create 3proxy configuration
echo "Creating 3proxy configuration..."
cat << EOF > /etc/3proxy/3proxy.cfg
daemon
maxconn 300
nserver [2606:4700:4700::1111]
nserver [2606:4700:4700::1001]
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
stacksize 6000
flush
auth strong
users $proxy_login:CL:password
allow $proxy_login

EOF

current_port=$port_start
while read -r ip; do
    echo "proxy -6 -s0 -n -a -p$current_port -i$(hostname -I | awk '{print $1}') -e$ip" >> /etc/3proxy/3proxy.cfg
    ((current_port++))
done < ip.list

echo "Configuration complete. Please reboot your system to apply changes."
