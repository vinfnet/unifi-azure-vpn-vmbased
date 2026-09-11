#!/usr/bin/env bash
set -euo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-unifi-azure-vpn-test}"
LOCATION="${LOCATION:-westeurope}"
RESOURCE_PREFIX="${RESOURCE_PREFIX:-unifi-azure-vpn}"
WORKSPACE_NAME="${RESOURCE_PREFIX}-logs"
ACTION_GROUP_NAME="${RESOURCE_PREFIX}-alerts"

if [[ -z "$SUBSCRIPTION_ID" ]]; then
    echo "SUBSCRIPTION_ID is required." >&2
    exit 1
fi

az account set --subscription "$SUBSCRIPTION_ID"
WORKSPACE_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.OperationalInsights/workspaces/$WORKSPACE_NAME"
ACTION_GROUP_ID="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Insights/actionGroups/$ACTION_GROUP_NAME"

create_alert() {
    local name="$1" display_name="$2" description="$3" query="$4" auto_mitigate="$5" window="$6"
    local alert_id="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.Insights/scheduledQueryRules/$name"
  local body_file query_json
    body_file="$(mktemp)"
  query_json="${query//\\/\\\\}"
  query_json="${query_json//\"/\\\"}"
    cat >"$body_file" <<EOF
{
  "location": "$LOCATION",
  "properties": {
    "displayName": "$display_name",
    "description": "$description",
    "severity": 2,
    "enabled": true,
    "evaluationFrequency": "PT1M",
    "windowSize": "$window",
    "scopes": ["$WORKSPACE_ID"],
    "targetResourceTypes": ["Microsoft.OperationalInsights/workspaces"],
    "autoMitigate": $auto_mitigate,
    "criteria": {
      "allOf": [{
        "query": "$query_json",
        "timeAggregation": "Count",
        "operator": "GreaterThan",
        "threshold": 0,
        "failingPeriods": {"numberOfEvaluationPeriods": 1, "minFailingPeriodsToAlert": 1}
      }]
    },
    "actions": {"actionGroups": ["$ACTION_GROUP_ID"]}
  }
}
EOF
    az rest --method put \
        --uri "https://management.azure.com${alert_id}?api-version=2023-12-01" \
        --body "@$body_file" >/dev/null
    rm -f "$body_file"
}

create_alert WireGuard-SSH-Login \
    "WireGuard SSH login" \
    "Successful SSH login or SSH remote command on the WireGuard server" \
    "Syslog | where ProcessName == 'sshd' and SyslogMessage contains 'Accepted '" \
    false PT1M

create_alert WireGuard-Disconnected \
    "WireGuard disconnected" \
    "WireGuard has no handshake within 180 seconds" \
    "Syslog | where ProcessName == 'wireguard-health' and SyslogMessage contains 'WIREGUARD_STATE=DISCONNECTED'" \
    true PT15M

create_alert WireGuard-Source-IP-Changed \
    "WireGuard source IP changed" \
    "WireGuard peer source IP changed, indicating WAN failover or an ISP address change" \
    "Syslog | where ProcessName == 'wireguard-health' and SyslogMessage contains 'WIREGUARD_ENDPOINT_CHANGED'" \
    true PT5M

create_alert WireGuard-Server-Rebooted \
    "WireGuard server rebooted" \
    "WireGuard server completed a reboot" \
    "Syslog | where ProcessName == 'wireguard-reboot' and SyslogMessage contains 'WIREGUARD_SERVER_REBOOTED'" \
    true PT15M

echo "SSH, disconnect, source IP change, reboot, and Run Command alerts are enabled."