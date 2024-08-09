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

if ping6 -c3 google.com &>/dev/null; then
  echo "Your server is ready to set up IPv6 proxies!"
else
  echo "Your server can't connect to IPv6 addresses."
  echo "Please, connect ipv6 interface to your server to continue."
  exit 1
fi

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

echo "↓ Server IPv4 address from tunnelbroker:"
read TUNNEL_IPV4_ADDR
if [[ ! "$TUNNEL_IPV4_ADDR" ]]; then
  echo "● IPv4 address can't be empty"
  exit 1
fi

echo "↓ Proxies login (can be blank):"
read PROXY_LOGIN

if [[ "$PROXY_LOGIN" ]]; then
  echo "↓ Proxies password:"
  read PROXY_PASS
  if [[ ! "$PROXY_PASS" ]]; then
    echo "● Proxies pass can't be empty"
    exit 1
  fi
fi

echo "↓ Port numbering start (default 1500):"
read PROXY_START_PORT
if [[ ! "$PROXY_START_PORT" ]]; then
  PROXY_START_PORT=1500
fi

echo "↓ Proxies count (default 1):"
read PROXY_COUNT
if [[ ! "$PROXY_COUNT" ]]; then
  PROXY_COUNT=1
fi

echo "↓ Proxies protocol (http, socks5; default http):"
read PROXY_PROTOCOL
if [[ $PROXY_PROTOCOL != "socks5" ]]; then
  PROXY_PROTOCOL="http"
fi

clear
sleep 1
PROXY_NETWORK=$(echo $PROXY_NETWORK | awk -F:: '{print $1}')
echo "● Network: $PROXY_NETWORK"
echo "● Network Mask: $PROXY_NET_MASK"
HOST_IPV4_ADDR=$(hostname -I | awk '{print $1}')
echo "● Host IPv4 address: $HOST_IPV4_ADDR"
echo "● Tunnel IPv4 address: $TUNNEL_IPV4_ADDR"
echo "● Proxies count: $PROXY_COUNT, starting from port: $PROXY_START_PORT"
echo "● Proxies protocol: $PROXY_PROTOCOL"
if [[ "$PROXY_LOGIN" ]]; then
  echo "● Proxies login: $PROXY_LOGIN"
  echo "● Proxies password: $PROXY_PASS"
fi

echo "-------------------------------------------------"
echo ">-- Updating packages and installing dependencies"
check_command apt-get update
check_command apt-get -y install gcc g++ make bc pwgen git

# Verify package installation
for pkg in gcc g++ make bc pwgen git; do
  if ! dpkg -s $pkg >/dev/null 2>&1; then
    echo "Error: Failed to install $pkg" >&2
    exit 1
  fi
done

echo ">-- Setting up sysctl.conf"
cat >>/etc/sysctl.conf <<END
net.ipv6.conf.eth0.proxy_ndp=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.forwarding=1
net.ipv6.ip_nonlocal_bind=1
net.ipv4.ip_local_port_range=1024 64000
net.ipv6.route.max_size=409600
net.ipv4.tcp_max_syn_backlog=4096
net.ipv6.neigh.default.gc_thresh3=102400
kernel.threads-max=1200000
kernel.max_map_count=6000000
vm.max_map_count=6000000
kernel.pid_max=2000000
END

echo ">-- Setting up logind.conf"
echo "UserTasksMax=1000000" >>/etc/systemd/logind.conf

echo ">-- Setting up system.conf"
cat >>/etc/systemd/system.conf <<END
UserTasksMax=1000000
DefaultMemoryAccounting=no
DefaultTasksAccounting=no
DefaultTasksMax=1000000
UserTasksMax=1000000
END

echo ">-- Setting up ndppd"
cd ~
check_command git clone --quiet https://github.com/DanielAdolfsson/ndppd.git
cd ~/ndppd
check_command make -k all
check_command make -k install
cat >~/ndppd/ndppd.conf <<END
route-ttl 30000
proxy he-ipv6 {
   router no
   timeout 500
   ttl 30000
   rule ${PROXY_NETWORK}::/${PROXY_NET_MASK} {
      static
   }
}
END

echo ">-- Setting up 3proxy"
cd ~
check_command wget -q https://github.com/z3APA3A/3proxy/archive/0.8.13.tar.gz
check_command tar xzf 0.8.13.tar.gz
mv ~/3proxy-0.8.13 ~/3proxy
rm 0.8.13.tar.gz
cd ~/3proxy
chmod +x src/
touch src/define.txt
echo "#define ANONYMOUS 1" >src/define.txt
sed -i '31r src/define.txt' src/proxy.h
check_command make -f Makefile.Linux
cat >~/3proxy/3proxy.cfg <<END
#!/bin/bash

daemon
maxconn 100
nserver 1.1.1.1
nscache 65536
timeouts 1 5 30 60 180 1800 15 60
setgid 65535
setuid 65535
stacksize 6000
flush
END

if [[ "$PROXY_LOGIN" ]]; then
  cat >>~/3proxy/3proxy.cfg <<END
auth strong
users ${PROXY_LOGIN}:CL:${PROXY_PASS}
allow ${PROXY_LOGIN}
END
else
  cat >>~/3proxy/3proxy.cfg <<END
auth none
END
fi

echo ">-- Generating IPv6 addresses"
touch ~/ip.list
touch ~/tunnels.txt

P_VALUES=(1 2 3 4 5 6 7 8 9 0 a b c d e f)
PROXY_GENERATING_INDEX=1
GENERATED_PROXY=""

generate_proxy() {
  a=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}
  b=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}
  c=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}
  d=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}
  e=${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}${P_VALUES[$RANDOM % 16]}

  echo "$PROXY_NETWORK:$a:$b:$c:$d$([ $PROXY_NET_MASK == 48 ] && echo ":$e" || echo "")" >>~/ip.list
}

while [ "$PROXY_GENERATING_INDEX" -le $PROXY_COUNT ]; do
  generate_proxy
  let "PROXY_GENERATING_INDEX+=1"
done

CURRENT_PROXY_PORT=${PROXY_START_PORT}
for e in $(cat ~/ip.list); do
  echo "$([ $PROXY_PROTOCOL == "socks5" ] && echo "socks" || echo "proxy") -6 -s0 -n -a -p$CURRENT_PROXY_PORT -i$HOST_IPV4_ADDR -e$e" >>~/3proxy/3proxy.cfg
  echo "$PROXY_PROTOCOL://$([ "$PROXY_LOGIN" ] && echo "$PROXY_LOGIN:$PROXY_PASS@" || echo "")$HOST_IPV4_ADDR:$CURRENT_PROXY_PORT" >>~/tunnels.txt
  let "CURRENT_PROXY_PORT+=1"
done

echo ">-- Creating IPv6 tunnel setup service"
cat > /etc/systemd/system/ipv6-tunnel.service <<EOL
[Unit]
Description=IPv6 Tunnel Setup
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup-ipv6-tunnel.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL

echo ">-- Creating IPv6 tunnel setup script"
cat > /usr/local/bin/setup-ipv6-tunnel.sh <<EOL
#!/bin/bash

# IPv6 Tunnel Setup
/sbin/ip tunnel add he-ipv6 mode sit remote ${TUNNEL_IPV4_ADDR} local ${HOST_IPV4_ADDR} ttl 255
/sbin/ip link set he-ipv6 up
/sbin/ip addr add ${PROXY_NETWORK}::2/64 dev he-ipv6
/sbin/ip -6 route add default via ${PROXY_NETWORK}::1 dev he-ipv6
/sbin/ip -6 route add ${PROXY_NETWORK}::/64 dev he-ipv6

# Enable IPv6 forwarding
sysctl -w net.ipv6.conf.all.forwarding=1

# Start ndppd
systemctl start ndppd
EOL

chmod +x /usr/local/bin/setup-ipv6-tunnel.sh

echo ">-- Updating rc.local"
cat > /etc/rc.local <<EOL
#!/bin/bash

ulimit -n 600000
ulimit -u 600000
ulimit -i 1200000
ulimit -s 1000000
ulimit -l 200000

# Start 3proxy
~/3proxy/src/3proxy ~/3proxy/3proxy.cfg

exit 0
EOL

chmod +x /etc/rc.local

echo ">-- Creating ndppd service"
cat > /etc/systemd/system/ndppd.service <<EOL
[Unit]
Description=NDP Proxy Daemon
After=network.target

[Service]
ExecStart=/root/ndppd/ndppd -d -c /root/ndppd/ndppd.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOL

# RELOAD systemd RIGHT HERE
systemctl daemon-reload


echo ">-- Enabling services"
systemctl daemon-reload
systemctl enable ipv6-tunnel.service
systemctl enable ndppd.service

echo ">-- Starting services"
systemctl start ipv6-tunnel.service
systemctl start ndppd.service

echo ">-- Verifying setup"

# Check if services are running
if ! systemctl is-active --quiet ndppd; then
  echo "Error: ndppd is not running" >&2
  exit 1
fi

if ! systemctl is-active --quiet ipv6-tunnel; then
  echo "Error: IPv6 tunnel setup failed" >&2
  exit 1
fi

if ! pgrep 3proxy >/dev/null; then
  echo "Error: 3proxy is not running" >&2
  exit 1
fi

# Check IPv6 connectivity (wait for up to 30 seconds)
for i in {1..6}; do
  if ping6 -c3 google.com &>/dev/null; then
    echo "IPv6 connectivity established"
    break
  elif [ $i -eq 6 ]; then
    echo "Error: IPv6 connectivity not working after setup" >&2
    exit 1
  else
    echo "Waiting for IPv6 connectivity..."
    sleep 5
  fi
done

# Check IPv6 tunnel
if ! ip -6 addr show dev he-ipv6 >/dev/null 2>&1; then
  echo "Error: IPv6 tunnel (he-ipv6) is not set up correctly" >&2
  exit 1
fi

echo "Setup completed successfully. Rebooting now..."
reboot now
