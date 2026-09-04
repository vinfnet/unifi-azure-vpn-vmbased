#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-unifi-azure-vpn-test}"
LOCATION="${LOCATION:-westeurope}"
VNET_CIDR="${VNET_CIDR:-10.240.20.0/24}"
SUBNET_CIDR="${SUBNET_CIDR:-10.240.20.0/27}"
VM_PRIVATE_IP="${VM_PRIVATE_IP:-10.240.20.4}"
LAN_CIDR="${LAN_CIDR:-}"
WG_CIDR="${WG_CIDR:-172.31.254.0/30}"
WG_SERVER_IP="${WG_SERVER_IP:-172.31.254.1}"
WG_UDM_IP="${WG_UDM_IP:-172.31.254.2}"
WG_PORT="${WG_PORT:-51820}"
VM_SIZE="${VM_SIZE:-Standard_B1ls}"
ADMIN_USER="${ADMIN_USER:-azureadmin}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$SCRIPT_DIR/.ssh/unifi-azure-vpn}"
UDM_CONFIG_PATH="${UDM_CONFIG_PATH:-$SCRIPT_DIR/udm-wireguard.conf}"
RESOURCE_PREFIX="${RESOURCE_PREFIX:-unifi-azure-vpn}"

VNET_NAME="${RESOURCE_PREFIX}-vnet"
SUBNET_NAME="vpn-subnet"
NSG_NAME="${RESOURCE_PREFIX}-nsg"
PIP_NAME="${RESOURCE_PREFIX}-pip"
NIC_NAME="${RESOURCE_PREFIX}-nic"
VM_NAME="${RESOURCE_PREFIX}-vm"

prompt_required() {
    local variable_name="$1" description="$2" example="$3" current_value
    current_value="${!variable_name}"
    if [[ -n "$current_value" ]]; then
        return
    fi
    if [[ ! -t 0 ]]; then
        echo "$variable_name is required. $description" >&2
        exit 1
    fi
    printf '\n%s\nExample: %s\n' "$description" "$example"
    while [[ -z "$current_value" ]]; do
        read -r -p "$variable_name: " current_value
    done
    printf -v "$variable_name" '%s' "$current_value"
}

prompt_required SUBSCRIPTION_ID \
    "Enter the Azure subscription UUID in which all VPN resources will be created. Find it with: az account list --output table" \
    "00000000-0000-0000-0000-000000000000"
prompt_required LAN_CIDR \
    "Enter the private CIDR of the LAN behind the UniFi gateway. Azure will route replies for this network through WireGuard." \
    "192.168.10.0/24"

for command_name in az ssh ssh-keygen scp curl; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Required command not found: $command_name" >&2
        exit 1
    }
done

ip_to_int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    printf '%u\n' "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}

cidr_bounds() {
    local cidr="$1" ip bits ip_int mask start end
    ip="${cidr%/*}"
    bits="${cidr#*/}"
    ip_int="$(ip_to_int "$ip")"
    if (( bits == 0 )); then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    fi
    start=$(( ip_int & mask ))
    end=$(( start | ((~mask) & 0xFFFFFFFF) ))
    printf '%u %u\n' "$start" "$end"
}

cidrs_overlap() {
    local a_start a_end b_start b_end
    read -r a_start a_end <<<"$(cidr_bounds "$1")"
    read -r b_start b_end <<<"$(cidr_bounds "$2")"
    (( a_start <= b_end && b_start <= a_end ))
}

echo "Checking Azure sign-in..."
if ! az account show >/dev/null 2>&1; then
    az login
fi
az account set --subscription "$SUBSCRIPTION_ID"
if [[ "$(az account show --query id --output tsv)" != "$SUBSCRIPTION_ID" ]]; then
    echo "Unable to select subscription $SUBSCRIPTION_ID" >&2
    exit 1
fi

if az group exists --name "$RESOURCE_GROUP" | grep -q true; then
    echo "Resource group $RESOURCE_GROUP already exists. Refusing to alter it." >&2
    echo "Run ./destroy.sh first, or choose a different RESOURCE_GROUP." >&2
    exit 1
fi

echo "Checking $VNET_CIDR and $WG_CIDR against all existing Azure VNets..."
while IFS= read -r existing_cidr; do
    [[ -z "$existing_cidr" ]] && continue
    if cidrs_overlap "$VNET_CIDR" "$existing_cidr" || cidrs_overlap "$WG_CIDR" "$existing_cidr"; then
        echo "Address-space conflict with existing Azure prefix: $existing_cidr" >&2
        exit 1
    fi
done < <(az network vnet list --query '[].addressSpace.addressPrefixes[]' --output tsv)

if cidrs_overlap "$VNET_CIDR" "$LAN_CIDR" || cidrs_overlap "$WG_CIDR" "$LAN_CIDR"; then
    echo "The selected Azure or WireGuard CIDR overlaps the UniFi LAN: $LAN_CIDR" >&2
    exit 1
fi

ADMIN_CIDR="${ADMIN_CIDR:-}"
if [[ -z "$ADMIN_CIDR" ]]; then
    ADMIN_IP="$(curl -4fsS https://api.ipify.org)"
    ADMIN_CIDR="$ADMIN_IP/32"
fi
echo "Restricting SSH access to $ADMIN_CIDR"

mkdir -p "$(dirname "$SSH_KEY_PATH")"
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C "$RESOURCE_GROUP" -f "$SSH_KEY_PATH"
fi

echo "Creating Azure resources in $LOCATION..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" \
    --tags purpose=wireguard-test managed-by=deploy-script >/dev/null

az network vnet create --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" \
    --location "$LOCATION" --address-prefixes "$VNET_CIDR" \
    --subnet-name "$SUBNET_NAME" --subnet-prefixes "$SUBNET_CIDR" >/dev/null

az network nsg create --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" \
    --location "$LOCATION" >/dev/null
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    --name AllowWireGuard --priority 100 --access Allow --direction Inbound \
    --protocol Udp --source-address-prefixes Internet --destination-port-ranges "$WG_PORT" >/dev/null
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    --name AllowSshFromAdmin --priority 110 --access Allow --direction Inbound \
    --protocol Tcp --source-address-prefixes "$ADMIN_CIDR" --destination-port-ranges 22 >/dev/null
az network nsg rule create --resource-group "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    --name AllowUnifiLan --priority 120 --access Allow --direction Inbound \
    --protocol '*' --source-address-prefixes "$LAN_CIDR" --destination-address-prefixes "$VNET_CIDR" >/dev/null

az network public-ip create --resource-group "$RESOURCE_GROUP" --name "$PIP_NAME" \
    --location "$LOCATION" --sku Standard --allocation-method Static >/dev/null
PUBLIC_IP="$(az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$PIP_NAME" \
    --query ipAddress --output tsv)"

az network nic create --resource-group "$RESOURCE_GROUP" --name "$NIC_NAME" \
    --location "$LOCATION" --vnet-name "$VNET_NAME" --subnet "$SUBNET_NAME" \
    --network-security-group "$NSG_NAME" --public-ip-address "$PIP_NAME" \
    --private-ip-address "$VM_PRIVATE_IP" --ip-forwarding true >/dev/null

az vm create --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --location "$LOCATION" \
    --nics "$NIC_NAME" --image Ubuntu2204 --size "$VM_SIZE" --admin-username "$ADMIN_USER" \
    --ssh-key-values "$SSH_KEY_PATH.pub" --authentication-type ssh \
    --os-disk-size-gb 32 --storage-sku Standard_LRS >/dev/null

SSH_OPTIONS=(-i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
echo "Waiting for SSH on $PUBLIC_IP..."
for attempt in {1..30}; do
    if ssh "${SSH_OPTIONS[@]}" "$ADMIN_USER@$PUBLIC_IP" true 2>/dev/null; then
        break
    fi
    if (( attempt == 30 )); then
        echo "VM did not become reachable by SSH." >&2
        exit 1
    fi
    sleep 10
done

echo "Installing and configuring WireGuard..."
scp "${SSH_OPTIONS[@]}" "$SCRIPT_DIR/configure-wireguard.sh" "$ADMIN_USER@$PUBLIC_IP:/tmp/configure-wireguard.sh"
ssh "${SSH_OPTIONS[@]}" "$ADMIN_USER@$PUBLIC_IP" \
    "sudo bash /tmp/configure-wireguard.sh '$PUBLIC_IP' '$VNET_CIDR' '$LAN_CIDR' '$WG_SERVER_IP' '$WG_UDM_IP' '$WG_PORT' '$ADMIN_USER'"
scp "${SSH_OPTIONS[@]}" "$ADMIN_USER@$PUBLIC_IP:/home/$ADMIN_USER/udm-wireguard.conf" "$UDM_CONFIG_PATH"
chmod 600 "$UDM_CONFIG_PATH"
ssh "${SSH_OPTIONS[@]}" "$ADMIN_USER@$PUBLIC_IP" "rm -f /home/$ADMIN_USER/udm-wireguard.conf"

cat <<EOF

Deployment complete.
  Resource group:       $RESOURCE_GROUP
  Azure VNet:           $VNET_CIDR
  Ping target:          $VM_PRIVATE_IP
  WireGuard endpoint:   $PUBLIC_IP:$WG_PORT
  UniFi configuration: $UDM_CONFIG_PATH
  SSH:                  ssh -i '$SSH_KEY_PATH' $ADMIN_USER@$PUBLIC_IP

The UniFi configuration contains a private key. Keep it secret and follow README.md.
EOF
