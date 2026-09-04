#!/usr/bin/env bash
set -euo pipefail

PUBLIC_IP="$1"
VNET_CIDR="$2"
LAN_CIDR="$3"
WG_SERVER_IP="$4"
WG_UDM_IP="$5"
WG_PORT="$6"
ADMIN_USER="$7"

export DEBIAN_FRONTEND=noninteractive
if [[ ! -f /swapfile ]]; then
    fallocate -l 1G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
apt-get update -qq
apt-get install -y -qq wireguard iptables unattended-upgrades

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer

install -d -m 700 /etc/wireguard
umask 077
wg genkey | tee /etc/wireguard/server.key | wg pubkey > /etc/wireguard/server.pub
wg genkey | tee /etc/wireguard/unifi.key | wg pubkey > /etc/wireguard/unifi.pub

SERVER_PRIVATE_KEY="$(cat /etc/wireguard/server.key)"
SERVER_PUBLIC_KEY="$(cat /etc/wireguard/server.pub)"
UNIFI_PRIVATE_KEY="$(cat /etc/wireguard/unifi.key)"
UNIFI_PUBLIC_KEY="$(cat /etc/wireguard/unifi.pub)"

cat >/etc/sysctl.d/99-wireguard-forwarding.conf <<EOF
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null

cat >/etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_SERVER_IP}/30
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT

[Peer]
# UniFi gateway
PublicKey = ${UNIFI_PUBLIC_KEY}
AllowedIPs = ${WG_UDM_IP}/32, ${LAN_CIDR}
EOF

cat >"/home/${ADMIN_USER}/udm-wireguard.conf" <<EOF
[Interface]
PrivateKey = ${UNIFI_PRIVATE_KEY}
Address = ${WG_UDM_IP}/30
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs = ${VNET_CIDR}, ${WG_SERVER_IP}/32
PersistentKeepalive = 25
EOF
chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/udm-wireguard.conf"
chmod 600 "/home/${ADMIN_USER}/udm-wireguard.conf"

# The gateway private key is copied out by deploy.sh and then removed from this VM.
rm -f /etc/wireguard/unifi.key
systemctl enable --now wg-quick@wg0
wg show wg0
