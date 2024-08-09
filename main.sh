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
check_command apt-get install -y python3-pip iptables-persistent

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

# Create Python proxy script
echo "Creating Python proxy script..."
cat > /usr/local/bin/simple_proxy.py <<EOL
import sys
import socket
import threading
import select

def forward(source, destination):
    string = ' '
    while string:
        string = source.recv(1024)
        if string:
            destination.sendall(string)
        else:
            source.shutdown(socket.SHUT_RD)
            destination.shutdown(socket.SHUT_WR)

def handle(client, addr):
    try:
        request = client.recv(1024)
        if not request:
            client.close()
            return
        
        if request.startswith(b'CONNECT'):
            host, port = request.split(b' ')[1].split(b':')
        else:
            host = request.split(b'\n')[1].split(b' ')[1]
            port = 80 if host.startswith(b'http://') else 443

        server = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        server.connect((host.decode(), int(port)))
        
        if request.startswith(b'CONNECT'):
            client.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
        else:
            server.sendall(request)

        threading.Thread(target=forward, args=(client, server)).start()
        threading.Thread(target=forward, args=(server, client)).start()
    except Exception as e:
        print(f"Error: {e}")
        client.close()
        try:
            server.close()
        except:
            pass

def main(port, ipv6_prefix):
    server = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((f"{ipv6_prefix}::2", port))
    server.listen(100)
    print(f"Proxy listening on [{ipv6_prefix}::2]:{port}")

    while True:
        client, addr = server.accept()
        threading.Thread(target=handle, args=(client, addr)).start()

if __name__ == "__main__":
    main(int(sys.argv[1]), sys.argv[2])
EOL

# Create systemd service for the proxy
echo "Creating systemd service for the proxy..."
cat > /etc/systemd/system/ipv6proxy.service <<EOL
[Unit]
Description=IPv6 Proxy Service
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/simple_proxy.py ${PROXY_START_PORT} ${PROXY_NETWORK}
Restart=always

[Install]
WantedBy=multi-user.target
EOL

# Enable and start the service
echo "Enabling and starting the proxy service..."
check_command systemctl daemon-reload
check_command systemctl enable ipv6proxy
check_command systemctl start ipv6proxy

echo "Setup completed successfully. Your IPv6 proxy should now be running."
echo "Proxy address: [${PROXY_NETWORK}::2]:${PROXY_START_PORT}"
