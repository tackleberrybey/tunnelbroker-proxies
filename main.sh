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

####
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

####
echo "↓ Server IPv4 address from tunnelbroker:"
read TUNNEL_IPV4_ADDR
if [[ ! "$TUNNEL_IPV4_ADDR" ]]; then
  echo "● IPv4 address can't be empty"
  exit 1
fi

####
echo "↓ Client IPv6 address for the tunnel:"
read CLIENT_IPV6_ADDR
if [[ ! "$CLIENT_IPV6_ADDR" ]]; then
  echo "● Client IPv6 address can't be empty"
  exit 1
fi

####
echo "↓ Server IPv6 address for the tunnel:"
read SERVER_IPV6_ADDR
if [[ ! "$SERVER_IPV6_ADDR" ]]; then
  echo "● Server IPv6 address can't be empty"
  exit 1
fi

####
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

####
echo "↓ Port numbering start (default 1500):"
read PROXY_START_PORT
if [[ ! "$PROXY_START_PORT" ]]; then
  PROXY_START_PORT=1500
fi

####
echo "↓ Proxies count (default 1):"
read PROXY_COUNT
if [[ ! "$PROXY_COUNT" ]]; then
  PROXY_COUNT=1
fi

####
echo "↓ Proxies protocol (http, socks5; default http):"
read PROXY_PROTOCOL
if [[ $PROXY_PROTOCOL != "socks5" ]]; then
  PROXY_PROTOCOL="http"
fi

####
clear
sleep 1
PROXY_NETWORK=$(echo $PROXY_NETWORK | awk -F:: '{print $1}')
echo "● Network: $PROXY_NETWORK"
echo "● Network Mask: $PROXY_NET_MASK"
HOST_IPV4_ADDR=$(hostname -I | awk '{print $1}')
echo "● Host IPv4 address: $HOST_IPV4_ADDR"
echo "● Tunnel IPv4 address: $TUNNEL_IPV4_ADDR"
echo "● Client IPv6 address: $CLIENT_IPV6_ADDR"
echo "● Server IPv6 address: $SERVER_IPV6_ADDR"
echo "● Proxies count: $PROXY_COUNT, starting from port: $PROXY_START_PORT"
echo "● Proxies protocol: $PROXY_PROTOCOL"
if [[ "$PROXY_LOGIN" ]]; then
  echo "● Proxies login: $PROXY_LOGIN"
  echo "● Proxies password: $PROXY_PASS"
fi

####
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

####
echo ">-- Setting up sysctl.conf"
cat >>/etc/sysctl.conf <<END
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv6.conf.all.proxy_ndp=1
net.ipv6.conf.default.proxy_ndp=1
net.ipv6.conf.all.accept_ra=2
net.ipv6.conf.default.accept_ra=2
END

####
echo ">-- Setting up IPv6 tunnel"
if ip tunnel show he-ipv6 > /dev/null 2>&1; then
    echo "Tunnel he-ipv6 already exists. Removing it..."
    ip tunnel del he-ipv6
fi
check_command ip tunnel add he-ipv6 mode sit remote $TUNNEL_IPV4_ADDR local $HOST_IPV4_ADDR ttl 255
check_command ip link set he-ipv6 up
check_command ip addr add $CLIENT_IPV6_ADDR dev he-ipv6
check_command ip -6 route add ${PROXY_NETWORK}::/${PROXY_NET_MASK} dev he-ipv6
SERVER_IPV6_ADDR_NO_MASK=$(echo $SERVER_IPV6_ADDR | cut -d'/' -f1)

# Replace the default route
check_command ip -6 route replace default via $SERVER_IPV6_ADDR_NO_MASK dev he-ipv6

# Remove any conflicting routes
ip -6 route del default via fe80::1 dev eth0 2>/dev/null || true
ip -6 route del 2000::/3 dev he-ipv6 2>/dev/null || true


# Apply sysctl changes
sysctl -p

####
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

####
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

####
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

####
echo ">-- Setting up rc.local"
cat >/etc/rc.local <<END
#!/bin/bash

ulimit -n 600000
ulimit -u 600000
ulimit -i 1200000
ulimit -s 1000000
ulimit -l 200000
/sbin/ip tunnel add he-ipv6 mode sit remote $TUNNEL_IPV4_ADDR local $HOST_IPV4_ADDR ttl 255
/sbin/ip link set he-ipv6 up
/sbin/ip addr add $CLIENT_IPV6_ADDR dev he-ipv6
/sbin/ip -6 route add ${PROXY_NETWORK}::/${PROXY_NET_MASK} dev he-ipv6
/sbin/ip -6 route replace default via ${SERVER_IPV6_ADDR%/*} dev he-ipv6
~/ndppd/ndppd -d -c ~/ndppd/ndppd.conf
sleep 2
~/3proxy/src/3proxy ~/3proxy/3proxy.cfg
exit 0

END
/bin/chmod +x /etc/rc.local

####
echo ">-- Verifying setup"

# Check if services are running
if ! pgrep ndppd >/dev/null; then
  echo "Error: ndppd is not running" >&2
  exit 1
fi

if ! pgrep 3proxy >/dev/null; then
  echo "Error: 3proxy is not running" >&2
  exit 1
fi

# Check IPv6 connectivity
if ! ping6 -c3 google.com &>/dev/null; then
  echo "Error: IPv6 connectivity not working after setup" >&2
  exit 1
fi

# Check IPv6 tunnel
if ! ip -6 addr show dev he-ipv6 >/dev/null 2>&1; then
  echo "Error: IPv6 tunnel (he-ipv6) is not set up correctly" >&2
  exit 1
fi

echo "Setup completed successfully. Rebooting now..."
reboot now
