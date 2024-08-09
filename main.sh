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

# Check if already configured (for idempotency)
if grep -q "miredo" /etc/sysctl.conf; then
  echo "IPv6 tunnel already configured."
else

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
  check_command apt-get -y install miredo iptables gcc g++ make bc pwgen git

  # Verify package installation
  for pkg in miredo iptables gcc g++ make bc pwgen git; do
    if ! dpkg -s $pkg >/dev/null 2>&1; then
      echo "Error: Failed to install $pkg" >&2
      exit 1
    fi
  done

  echo ">-- Configuring Miredo"
  check_command systemctl stop miredo
  check_command systemctl disable miredo

  # Configure sysctl for IPv6 forwarding and other optimizations
  cat >> /etc/sysctl.conf <<EOL
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.ip_nonlocal_bind=1
net.ipv4.ip_local_port_range=1024 64000
net.ipv6.route.max_size=409600
net.ipv4.tcp_max_syn_backlog=4096
net.ipv6.neigh.default.gc_thresh3=102400
kernel.threads-max = 1200000
kernel.pid_max = 2000000
EOL

  check_command sysctl -p /etc/sysctl.conf

  # Set vm.max_map_count (this does not use sysctl)
  echo "vm.max_map_count = 6000000" > /etc/sysctl.d/99-max-map-count.conf

  echo ">-- Setting up logind.conf"
  echo "UserTasksMax=1000000" >> /etc/systemd/logind.conf

  echo ">-- Setting up system.conf"
  cat >> /etc/systemd/system.conf <<EOL
UserTasksMax=1000000
DefaultMemoryAccounting=no
DefaultTasksAccounting=no
DefaultTasksMax=1000000
UserTasksMax=1000000
EOL

  # Configure firewall rules (assuming you are using iptables)
  echo ">-- Setting up iptables"
  check_command iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  check_command ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  check_command netfilter-persistent save

fi # End of the initial configuration block

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

echo ">-- Starting Miredo service"
systemctl enable --now miredo
systemctl start miredo

# Wait for Miredo to establish a tunnel
echo "Waiting for Miredo to establish a tunnel (this may take a few minutes)..."
timeout 120 bash -c 'until ping6 -c1 2001:4860:4860::8888 > /dev/null 2>&1; do sleep 1; done'

if [[ $? -eq 124 ]]; then
  echo "Error: Timeout while waiting for Miredo tunnel" >&2
  exit 1
fi

echo ">-- Verifying setup"

# Check IPv6 connectivity
if ! ping6 -c3 google.com &>/dev/null; then
  echo "Error: IPv6 connectivity not working after setup" >&2
  exit 1
fi

echo "Setup completed successfully. Your IPv6 proxies should be working now!"
