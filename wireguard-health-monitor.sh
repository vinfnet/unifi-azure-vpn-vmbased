#!/usr/bin/env bash
set -euo pipefail

INTERFACE="${INTERFACE:-wg0}"
MAX_HANDSHAKE_AGE="${MAX_HANDSHAKE_AGE:-180}"
STATE_FILE="${STATE_FILE:-/run/wireguard-health-monitor.state}"
ENDPOINT_STATE_FILE="${ENDPOINT_STATE_FILE:-/run/wireguard-health-monitor.endpoint}"

current_state="DISCONNECTED"
reason="interface unavailable"
latest_handshake=0

if systemctl is-active --quiet "wg-quick@${INTERFACE}"; then
    latest_handshake="$(wg show "$INTERFACE" latest-handshakes | awk 'NR == 1 { print $2 }')"
    latest_handshake="${latest_handshake:-0}"
    current_epoch="$(date +%s)"
    if (( latest_handshake > 0 && current_epoch - latest_handshake <= MAX_HANDSHAKE_AGE )); then
        current_state="CONNECTED"
        reason="handshake age $((current_epoch - latest_handshake)) seconds"
    else
        reason="no handshake within ${MAX_HANDSHAKE_AGE} seconds"
    fi
fi

previous_state="UNKNOWN"
if [[ -f "$STATE_FILE" ]]; then
    previous_state="$(<"$STATE_FILE")"
fi
printf '%s\n' "$current_state" >"$STATE_FILE"

if [[ "$current_state" == "DISCONNECTED" ]]; then
    logger --tag wireguard-health --priority daemon.warning \
        "WIREGUARD_STATE=DISCONNECTED interface=$INTERFACE reason=$reason"
elif [[ "$previous_state" != "CONNECTED" ]]; then
    logger --tag wireguard-health --priority daemon.notice \
        "WIREGUARD_STATE=CONNECTED interface=$INTERFACE reason=$reason"
fi

if [[ "$current_state" == "CONNECTED" ]]; then
    endpoint="$(wg show "$INTERFACE" endpoints | awk 'NR == 1 { print $2 }')"
    source_ip=""
    if [[ "$endpoint" =~ ^\[([^]]+)\]:[0-9]+$ ]]; then
        source_ip="${BASH_REMATCH[1]}"
    elif [[ "$endpoint" == *:* && "$endpoint" != "(none)" ]]; then
        source_ip="${endpoint%:*}"
    fi

    if [[ -z "$source_ip" && "$endpoint" != "(none)" ]]; then
        logger --tag wireguard-health --priority daemon.warning \
            "WIREGUARD_ENDPOINT_PARSE_FAILED interface=$INTERFACE endpoint=$endpoint"
    fi

    previous_source_ip=""
    if [[ -f "$ENDPOINT_STATE_FILE" ]]; then
        previous_source_ip="$(<"$ENDPOINT_STATE_FILE")"
    fi
    printf '%s\n' "$source_ip" >"$ENDPOINT_STATE_FILE"

    if [[ -n "$source_ip" && -n "$previous_source_ip" && "$source_ip" != "$previous_source_ip" ]]; then
        logger --tag wireguard-health --priority daemon.notice \
            "WIREGUARD_ENDPOINT_CHANGED interface=$INTERFACE previous_source_ip=$previous_source_ip source_ip=$source_ip"
    fi
fi