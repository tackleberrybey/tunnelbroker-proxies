#!/bin/bash

# Update and install dependencies
apt update && apt upgrade -y
apt-get install -y git mc make htop build-essential speedtest-cli curl wget ncdu tmux psmisc net-tools

# Create directory for proxy
mkdir -p /app/proxy/ipv6-socks5-proxy
chown -R $USER:$USER /app/proxy/ipv6-socks5-proxy
cd /app/proxy/ipv6-socks5-proxy

# Get user input for IPv6 prefix and count
echo "Enter your IPv6 prefix (e.g., 2a09:04c0:aee0:023d::/64):"
read IPV6_PREFIX
echo "Enter the number of IPv6 addresses to generate:"
read IP_COUNT

# Generate IPv6 addresses
python3 -c "
import ipaddress
import random

network = ipaddress.IPv6Network('$IPV6_PREFIX')
with open('ip.list', 'w') as f:
    for _ in range($IP_COUNT):
        addr = network.network_address + random.getrandbits(128 - network.prefixlen)
        f.write(str(addr) + '\n')
"

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
cat << EOF > /etc/network/interfaces
auto he-ipv6
iface he-ipv6 inet6 v4tunnel
        address 2a09:4c0:aee0:227::2
        netmask 64
        endpoint 185.181.60.47
        local 188.245.99.243
        ttl 255
        gateway 2a09:4c0:aee0:227::1

up /app/proxy/ipv6-socks5-proxy/ifaceup.sh
down /app/proxy/ipv6-socks5-proxy/ifacedown.sh
EOF

# Configure kernel parameters
cat << EOF >> /etc/sysctl.conf
fs.file-max = 500000
EOF

cat << EOF >> /etc/security/limits.conf
* hard nofile 500000
* soft nofile 500000
root hard nofile 500000
root soft nofile 500000
* soft nproc 4000
* hard nproc 16000
root - memlock unlimited
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 3
EOF

cat << EOF >> /etc/systemd/system.conf
DefaultLimitDATA=infinity
DefaultLimitSTACK=infinity
DefaultLimitCORE=infinity
DefaultLimitRSS=infinity
DefaultLimitNOFILE=102400
DefaultLimitAS=infinity
DefaultLimitNPROC=10240
DefaultLimitMEMLOCK=infinity
EOF

cat << EOF >> /etc/systemd/user.conf
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
git clone https://github.com/z3APA3A/3proxy.git
cd 3proxy
ln -s Makefile.Linux Makefile
echo "#define ANONYMOUS 1" > src/define.txt
sed -i '31r src/define.txt' src/proxy.h
make
make install

# Create 3proxy configuration script
cat << 'EOF' > /app/proxy/ipv6-socks5-proxy/genproxy48.sh
#!/bin/bash

ipv4=$(hostname --ip-address)
portproxy=20000
user=test
pass=123
config="/etc/3proxy/3proxy.cfg"

echo -ne > $config
echo -ne > /app/proxy/ipv6-socks5-proxy/proxylist_key_collector.txt
echo -ne > /app/proxy/ipv6-socks5-proxy/xevil.txt

echo "daemon" >> $config
echo "maxconn 300" >> $config
echo "nserver [2606:4700:4700::1111]" >> $config
echo "nserver [2606:4700:4700::1001]" >> $config
echo "nserver [2001:4860:4860::8888]" >> $config
echo "nserver [2001:4860:4860::8844]" >> $config
echo "nserver [2a02:6b8::feed:0ff]" >> $config
echo "nserver [2a02:6b8:0:1::feed:0ff]" >> $config
echo "nscache 65536" >> $config
echo "nscache6 65536" >> $config
echo "timeouts 1 5 30 60 180 1800 15 60" >> $config
echo "stacksize 6000" >> $config
echo "flush" >> $config
echo "auth strong" >> $config
echo "users $user:CL:$pass" >> $config
echo "allow $user" >> $config

while read -r i; do
    echo "proxy -6 -s0 -n -a -olSO_REUSEADDR,SO_REUSEPORT -ocTCP_TIMESTAMPS,TCP_NODELAY -osTCP_NODELAY,SO_KEEPALIVE -p$portproxy -i$ipv4 -e$i" >> $config
    echo "$ipv4:$portproxy@$user:$pass;v6;http" >> proxylist_key_collector.txt
    echo "http://$user:$pass@$ipv4:$portproxy" >> xevil.txt
    ((portproxy+=1))
done < ip.list
EOF

chmod +x /app/proxy/ipv6-socks5-proxy/genproxy48.sh

# Run 3proxy configuration script
/app/proxy/ipv6-socks5-proxy/genproxy48.sh

# Restart 3proxy service
systemctl restart 3proxy.service

echo "Setup complete. Please reboot your system for changes to take effect."
