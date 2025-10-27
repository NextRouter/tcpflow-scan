#!/bin/bash
set -e

# WireGuard Server Setup Script for GCP
# This script sets up a WireGuard VPN server on a GCP VM instance

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
WG_INTERFACE="wg0"
WG_PORT=51820
WG_CONFIG_DIR="/etc/wireguard"
SERVER_PRIVATE_KEY_FILE="${WG_CONFIG_DIR}/server_private.key"
SERVER_PUBLIC_KEY_FILE="${WG_CONFIG_DIR}/server_public.key"

echo -e "${GREEN}=== WireGuard Server Setup for GCP ===${NC}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}Cannot detect OS${NC}"
    exit 1
fi

echo -e "${YELLOW}Installing WireGuard...${NC}"

# Install WireGuard
case $OS in
    ubuntu|debian)
        apt-get update
        apt-get install -y wireguard wireguard-tools qrencode iptables
        ;;
    centos|rhel|fedora)
        yum install -y epel-release
        yum install -y wireguard-tools qrencode iptables
        ;;
    *)
        echo -e "${RED}Unsupported OS: $OS${NC}"
        exit 1
        ;;
esac

# Enable IP forwarding
echo -e "${YELLOW}Enabling IP forwarding...${NC}"
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard.conf
echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-wireguard.conf
sysctl -p /etc/sysctl.d/99-wireguard.conf

# Create configuration directory
mkdir -p ${WG_CONFIG_DIR}
chmod 700 ${WG_CONFIG_DIR}

# Generate server keys if they don't exist
if [ ! -f ${SERVER_PRIVATE_KEY_FILE} ]; then
    echo -e "${YELLOW}Generating server keys...${NC}"
    wg genkey | tee ${SERVER_PRIVATE_KEY_FILE} | wg pubkey > ${SERVER_PUBLIC_KEY_FILE}
    chmod 600 ${SERVER_PRIVATE_KEY_FILE}
    chmod 644 ${SERVER_PUBLIC_KEY_FILE}
fi

SERVER_PRIVATE_KEY=$(cat ${SERVER_PRIVATE_KEY_FILE})
SERVER_PUBLIC_KEY=$(cat ${SERVER_PUBLIC_KEY_FILE})

# Get the default network interface
DEFAULT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)

# Get server's public IP
echo -e "${YELLOW}Detecting server public IP...${NC}"
SERVER_PUBLIC_IP=$(curl -s https://api.ipify.org)
if [ -z "$SERVER_PUBLIC_IP" ]; then
    SERVER_PUBLIC_IP=$(curl -s http://checkip.amazonaws.com)
fi

if [ -z "$SERVER_PUBLIC_IP" ]; then
    echo -e "${RED}Could not detect public IP. Please enter manually:${NC}"
    read -p "Server Public IP: " SERVER_PUBLIC_IP
fi

echo -e "${GREEN}Server Public IP: ${SERVER_PUBLIC_IP}${NC}"

# Create WireGuard server configuration
echo -e "${YELLOW}Creating WireGuard server configuration...${NC}"
cat > ${WG_CONFIG_DIR}/${WG_INTERFACE}.conf <<EOF
[Interface]
Address = 10.8.0.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}

# Post-up and post-down rules for NAT
PostUp = iptables -A FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_INTERFACE} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_INTERFACE} -j MASQUERADE

EOF

chmod 600 ${WG_CONFIG_DIR}/${WG_INTERFACE}.conf

# Enable and start WireGuard
echo -e "${YELLOW}Enabling and starting WireGuard service...${NC}"
systemctl enable wg-quick@${WG_INTERFACE}
systemctl start wg-quick@${WG_INTERFACE}

# Configure firewall for GCP
echo -e "${YELLOW}Configuring firewall...${NC}"

# Create firewall rule using gcloud (if gcloud is available)
if command -v gcloud &> /dev/null; then
    echo -e "${YELLOW}Creating GCP firewall rule...${NC}"
    gcloud compute firewall-rules create wireguard-${WG_PORT} \
        --allow=udp:${WG_PORT} \
        --description="WireGuard VPN" \
        --direction=INGRESS \
        --target-tags=wireguard-server \
        2>/dev/null || echo -e "${YELLOW}Firewall rule may already exist or gcloud not configured${NC}"
    
    echo -e "${YELLOW}Note: Add 'wireguard-server' network tag to your VM instance${NC}"
else
    echo -e "${YELLOW}gcloud not found. Please manually create a firewall rule:${NC}"
    echo -e "  Protocol: UDP"
    echo -e "  Port: ${WG_PORT}"
    echo -e "  Source: 0.0.0.0/0"
fi

# Create client configuration function
create_client() {
    local CLIENT_NAME=$1
    local CLIENT_IP=$2
    local CLIENT_DIR="${WG_CONFIG_DIR}/clients/${CLIENT_NAME}"
    
    mkdir -p ${CLIENT_DIR}
    
    # Generate client keys
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(echo ${CLIENT_PRIVATE_KEY} | wg pubkey)
    CLIENT_PRESHARED_KEY=$(wg genpsk)
    
    # Save keys
    echo ${CLIENT_PRIVATE_KEY} > ${CLIENT_DIR}/private.key
    echo ${CLIENT_PUBLIC_KEY} > ${CLIENT_DIR}/public.key
    echo ${CLIENT_PRESHARED_KEY} > ${CLIENT_DIR}/preshared.key
    chmod 600 ${CLIENT_DIR}/*.key
    
    # Create client config
    cat > ${CLIENT_DIR}/${CLIENT_NAME}.conf <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/32
DNS = 8.8.8.8, 8.8.4.4

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
    
    # Add peer to server configuration
    cat >> ${WG_CONFIG_DIR}/${WG_INTERFACE}.conf <<EOF

# Client: ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32
EOF
    
    # Restart WireGuard to apply changes
    systemctl restart wg-quick@${WG_INTERFACE}
    
    # Generate QR code
    qrencode -t ansiutf8 < ${CLIENT_DIR}/${CLIENT_NAME}.conf
    
    echo -e "${GREEN}Client configuration created: ${CLIENT_DIR}/${CLIENT_NAME}.conf${NC}"
    echo -e "${GREEN}Client Public Key: ${CLIENT_PUBLIC_KEY}${NC}"
    echo -e "\n${YELLOW}QR Code (scan with WireGuard mobile app):${NC}"
    qrencode -t ansiutf8 < ${CLIENT_DIR}/${CLIENT_NAME}.conf
    echo -e "\n${GREEN}Configuration saved to: ${CLIENT_DIR}/${CLIENT_NAME}.conf${NC}"
}

# Create first client
echo -e "\n${GREEN}=== Setup Complete ===${NC}"
echo -e "${GREEN}Server Public Key: ${SERVER_PUBLIC_KEY}${NC}"
echo -e "${GREEN}Server Public IP: ${SERVER_PUBLIC_IP}${NC}"
echo -e "${GREEN}WireGuard Port: ${WG_PORT}${NC}"

# Ask if user wants to create a client now
read -p "Do you want to create a client configuration now? (y/n): " CREATE_CLIENT
if [[ $CREATE_CLIENT == "y" || $CREATE_CLIENT == "Y" ]]; then
    read -p "Enter client name: " CLIENT_NAME
    read -p "Enter client IP (e.g., 10.8.0.2): " CLIENT_IP
    
    if [ -z "$CLIENT_NAME" ] || [ -z "$CLIENT_IP" ]; then
        echo -e "${RED}Client name and IP are required${NC}"
    else
        create_client ${CLIENT_NAME} ${CLIENT_IP}
    fi
fi

# Create helper script for adding clients
cat > /usr/local/bin/wg-add-client <<'EOF'
#!/bin/bash
# Helper script to add WireGuard clients

if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: wg-add-client <client-name> <client-ip>"
    echo "Example: wg-add-client laptop 10.8.0.2"
    exit 1
fi

WG_CONFIG_DIR="/etc/wireguard"
WG_INTERFACE="wg0"
SERVER_PUBLIC_KEY=$(cat ${WG_CONFIG_DIR}/server_public.key)
SERVER_PUBLIC_IP=$(curl -s https://api.ipify.org)
WG_PORT=51820

CLIENT_NAME=$1
CLIENT_IP=$2
CLIENT_DIR="${WG_CONFIG_DIR}/clients/${CLIENT_NAME}"

mkdir -p ${CLIENT_DIR}

CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo ${CLIENT_PRIVATE_KEY} | wg pubkey)
CLIENT_PRESHARED_KEY=$(wg genpsk)

echo ${CLIENT_PRIVATE_KEY} > ${CLIENT_DIR}/private.key
echo ${CLIENT_PUBLIC_KEY} > ${CLIENT_DIR}/public.key
echo ${CLIENT_PRESHARED_KEY} > ${CLIENT_DIR}/preshared.key
chmod 600 ${CLIENT_DIR}/*.key

cat > ${CLIENT_DIR}/${CLIENT_NAME}.conf <<CLIENTCONF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/32
DNS = 8.8.8.8, 8.8.4.4

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
Endpoint = ${SERVER_PUBLIC_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
CLIENTCONF

cat >> ${WG_CONFIG_DIR}/${WG_INTERFACE}.conf <<PEERCONF

# Client: ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
PresharedKey = ${CLIENT_PRESHARED_KEY}
AllowedIPs = ${CLIENT_IP}/32
PEERCONF

systemctl restart wg-quick@${WG_INTERFACE}

echo "Client configuration created: ${CLIENT_DIR}/${CLIENT_NAME}.conf"
echo ""
echo "QR Code:"
qrencode -t ansiutf8 < ${CLIENT_DIR}/${CLIENT_NAME}.conf
EOF

chmod +x /usr/local/bin/wg-add-client

echo -e "\n${GREEN}=== Helper Commands ===${NC}"
echo -e "Add new client: ${YELLOW}wg-add-client <name> <ip>${NC}"
echo -e "Check status: ${YELLOW}wg show${NC}"
echo -e "View config: ${YELLOW}cat /etc/wireguard/wg0.conf${NC}"
echo -e "Restart service: ${YELLOW}systemctl restart wg-quick@wg0${NC}"
echo -e "\n${GREEN}WireGuard server is now running!${NC}"
