#!/bin/bash

# Function to check IPv6 connectivity
check_ipv6() {
    if ping6 -c3 google.com &>/dev/null; then
        echo "Your server is ready to set up IPv6 proxies!"
    else
        echo "Your server can't connect to IPv6 addresses."
        echo "Please connect an IPv6 interface to your server to continue."
        exit 1
    fi
}

# Function to get user input
get_input() {
    echo "↓ Routed /48 or /64 IPv6 prefix from tunnelbroker (*:*:*::/*):"
    read PROXY_NETWORK

    if [[ $PROXY_NETWORK == *"::/48"* ]]; then
        PROXY_NET_MASK=48
    elif [[ $PROXY_NETWORK == *"::/64"* ]]; then
        PROXY_NET_MASK=64
    else
        echo "● Unsupported IPv6 prefix format: $PROXY_NETWORK"
        exit 1
    fi

    echo "↓ Server IPv4 address:"
    read HOST_IPV4_ADDR

    echo "↓ Tunnel IPv4 address:"
    read TUNNEL_IPV4_ADDR

    echo "↓ Proxies login (can be blank):"
    read PROXY_LOGIN

    if [[ "$PROXY_LOGIN" ]]; then
        echo "↓ Proxies password:"
        read PROXY_PASS
    fi

    echo "↓ Port numbering start (default 20000):"
    read PROXY_START_PORT
    PROXY_START_PORT=${PROXY_START_PORT:-20000}

    echo "↓ Proxies count (default 500):"
    read PROXY_COUNT
    PROXY_COUNT=${PROXY_COUNT:-500}
}

# Function to update and install dependencies
update_and_install() {
    apt update && apt upgrade -y
    apt-get install -y git mc make htop build-essential speedtest-cli curl wget ncdu tmux psmisc net-tools
}

# Function to set up directories
setup_directories() {
    mkdir -p /app/proxy/ipv6-socks5-proxy
    chown -R $USER:$USER /app/proxy/ipv6-socks5-proxy
    cd /app/proxy/ipv6-socks5-proxy
}

# Function to generate IPv6 addresses
generate_ipv6_addresses() {
    # This is a simplified version. You might want to use a more sophisticated method
    for i in $(seq 1 $PROXY_COUNT); do
        printf "$PROXY_NETWORK:%04x:%04x:%04x:%04x\n" $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) $((RANDOM%65536)) >> ip.list
    done
}

# Function to create interface scripts
create_interface_scripts() {
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
}

# Function to configure network interface
configure_network_interface() {
    cat > /etc/network/interfaces.d/he-ipv6 <<EOF
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
        address ${PROXY_NETWORK}::2
        netmask $PROXY_NET_MASK
        endpoint $TUNNEL_IPV4_ADDR
        local $HOST_IPV4_ADDR
        ttl 255
        gateway ${PROXY_NETWORK}::1

up /app/proxy/ipv6-socks5-proxy/ifaceup.sh
down /app/proxy/ipv6-socks5-proxy/ifacedown.sh
EOF
}

# Function to adjust kernel parameters
adjust_kernel_parameters() {
    cat >> /etc/sysctl.conf <<EOF
fs.file-max = 500000
EOF

    cat >> /etc/security/limits.conf <<EOF
* hard nofile 500000
* soft nofile 500000
root hard nofile 500000
root soft nofile 500000
* soft nproc 4000
* hard nproc 16000
root - memlock unlimited
EOF

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
}

# Function to install and configure 3proxy
install_configure_3proxy() {
    cd /app/proxy/ipv6-socks5-proxy
    git clone https://github.com/z3APA3A/3proxy.git
    cd 3proxy
    ln -s Makefile.Linux Makefile
    echo "#define ANONYMOUS 1" > src/define.txt
    sed -i '31r src/define.txt' src/proxy.h
    make
    make install

    # Create 3proxy configuration script
    cat > /app/proxy/ipv6-socks5-proxy/genproxy48.sh <<EOF
#!/bin/bash

ipv4=$HOST_IPV4_ADDR
portproxy=$PROXY_START_PORT
user=$PROXY_LOGIN
pass=$PROXY_PASS
config="/etc/3proxy/3proxy.cfg"

echo -ne > \$config
echo -ne > /app/proxy/ipv6-socks5-proxy/proxylist.txt

echo "daemon" >> \$config
echo "maxconn 300" >> \$config
echo "nserver [2606:4700:4700::1111]" >> \$config
echo "nserver [2606:4700:4700::1001]" >> \$config
echo "nscache 65536" >> \$config
echo "timeouts 1 5 30 60 180 1800 15 60" >> \$config
echo "stacksize 6000" >> \$config
echo "flush" >> \$config
echo "auth strong" >> \$config
echo "users \$user:CL:\$pass" >> \$config
echo "allow \$user" >> \$config

while read -r ip; do
    echo "proxy -6 -s0 -n -a -p\$portproxy -i\$ipv4 -e\$ip" >> \$config
    echo "socks5://\$user:\$pass@\$ipv4:\$portproxy" >> /app/proxy/ipv6-socks5-proxy/proxylist.txt
    ((portproxy+=1))
done < /app/proxy/ipv6-socks5-proxy/ip.list
EOF

    chmod +x /app/proxy/ipv6-socks5-proxy/genproxy48.sh
    /app/proxy/ipv6-socks5-proxy/genproxy48.sh
}

# Main execution
check_ipv6
get_input
update_and_install
setup_directories
generate_ipv6_addresses
create_interface_scripts
configure_network_interface
adjust_kernel_parameters
install_configure_3proxy

echo "Setup complete. Please reboot your system to apply all changes."
echo "After reboot, your proxies will be available and listed in /app/proxy/ipv6-socks5-proxy/proxylist.txt"
