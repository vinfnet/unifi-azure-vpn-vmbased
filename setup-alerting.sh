#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
ALERT_EMAIL="${ALERT_EMAIL:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-unifi-azure-vpn-test}"
LOCATION="${LOCATION:-westeurope}"
RESOURCE_PREFIX="${RESOURCE_PREFIX:-unifi-azure-vpn}"
WG_SERVER_IP="${WG_SERVER_IP:-172.31.254.1}"
ADMIN_USER="${ADMIN_USER:-azureadmin}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$SCRIPT_DIR/.ssh/unifi-azure-vpn}"
VM_NAME="${RESOURCE_PREFIX}-vm"
WORKSPACE_NAME="${RESOURCE_PREFIX}-logs"
ACTION_GROUP_NAME="${RESOURCE_PREFIX}-alerts"
DCR_NAME="${RESOURCE_PREFIX}-syslog"

prompt_required() {
    local variable_name="$1" description="$2" current_value
    current_value="${!variable_name}"
    if [[ -n "$current_value" ]]; then
        return
    fi
    if [[ ! -t 0 ]]; then
        echo "$variable_name is required. $description" >&2
        exit 1
    fi
    printf '\n%s\n' "$description"
    while [[ -z "$current_value" ]]; do
        read -r -p "$variable_name: " current_value
    done
    printf -v "$variable_name" '%s' "$current_value"
}

prompt_required SUBSCRIPTION_ID "Enter the Azure subscription UUID containing the VPN deployment."
prompt_required ALERT_EMAIL "Enter the email address that should receive VPN alerts."

for command_name in az ssh scp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Required command not found: $command_name" >&2
        exit 1
    }
done

az account set --subscription "$SUBSCRIPTION_ID"
VM_ID="$(az vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" --query id -o tsv)"
WORKSPACE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/$WORKSPACE_NAME"
ACTION_GROUP_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Insights/actionGroups/$ACTION_GROUP_NAME"
DCR_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Insights/dataCollectionRules/$DCR_NAME"

az monitor log-analytics workspace create -g "$RESOURCE_GROUP" -n "$WORKSPACE_NAME" \
    -l "$LOCATION" --retention-time 30 >/dev/null
az monitor action-group create -g "$RESOURCE_GROUP" -n "$ACTION_GROUP_NAME" \
    --short-name WGAlerts --action email Admin "$ALERT_EMAIL" usecommonalertschema >/dev/null
az monitor activity-log alert create -g "$RESOURCE_GROUP" -n 'WireGuard-RunCommand' \
    --description "Azure Run Command executed on the WireGuard server" \
    --scope "$VM_ID" --action-group "$ACTION_GROUP_ID" \
    --condition category=Administrative and \
        operationName=Microsoft.Compute/virtualMachines/runCommand/action and status=Started >/dev/null

az vm identity assign -g "$RESOURCE_GROUP" -n "$VM_NAME" >/dev/null
az vm extension set -g "$RESOURCE_GROUP" --vm-name "$VM_NAME" \
    -n AzureMonitorLinuxAgent --publisher Microsoft.Azure.Monitor \
    --enable-auto-upgrade true >/dev/null

dcr_file="$(mktemp)"
trap 'rm -f "$dcr_file"' EXIT
cat >"$dcr_file" <<EOF
{
  "location": "$LOCATION",
  "properties": {
    "dataSources": {
      "syslog": [{
        "name": "wireguardSyslog",
        "streams": ["Microsoft-Syslog"],
        "facilityNames": ["auth", "authpriv", "daemon"],
        "logLevels": ["Debug", "Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]
      }]
    },
    "destinations": {
      "logAnalytics": [{
        "name": "wireguardWorkspace",
        "workspaceResourceId": "$WORKSPACE_ID"
      }]
    },
    "dataFlows": [{
      "streams": ["Microsoft-Syslog"],
      "destinations": ["wireguardWorkspace"]
    }]
  }
}
EOF
az rest --method put --uri "https://management.azure.com${DCR_ID}?api-version=2022-06-01" \
    --body "@$dcr_file" >/dev/null
az monitor data-collection rule association create \
    --name "${RESOURCE_PREFIX}-vm-syslog" --rule-id "$DCR_ID" --resource "$VM_ID" >/dev/null

SSH_OPTIONS=(-i "$SSH_KEY_PATH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
scp "${SSH_OPTIONS[@]}" "$SCRIPT_DIR/wireguard-health-monitor.sh" \
    "$SCRIPT_DIR/wireguard-health-monitor.service" \
    "$SCRIPT_DIR/wireguard-health-monitor.timer" \
    "$SCRIPT_DIR/wireguard-boot-notify.service" \
    "$ADMIN_USER@$WG_SERVER_IP:/tmp/"
ssh "${SSH_OPTIONS[@]}" "$ADMIN_USER@$WG_SERVER_IP" \
  'set -e; sudo install -m 0755 /tmp/wireguard-health-monitor.sh /usr/local/sbin/wireguard-health-monitor; sudo install -m 0644 /tmp/wireguard-health-monitor.service /etc/systemd/system/wireguard-health-monitor.service; sudo install -m 0644 /tmp/wireguard-health-monitor.timer /etc/systemd/system/wireguard-health-monitor.timer; sudo install -m 0644 /tmp/wireguard-boot-notify.service /etc/systemd/system/wireguard-boot-notify.service; sudo rm -f /tmp/wireguard-health-monitor.* /tmp/wireguard-boot-notify.service; sudo systemctl daemon-reload; sudo systemctl enable --now wireguard-health-monitor.timer wireguard-boot-notify.service; sudo systemctl start wireguard-health-monitor.service'

cat <<EOF
Azure Monitor collection is deployed.
Email receiver: $ALERT_EMAIL
Workspace: $WORKSPACE_NAME

Log ingestion can take several minutes. Run ./setup-log-alerts.sh after Syslog data appears.
EOF