#!/usr/bin/env bash
set -euo pipefail

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-unifi-azure-vpn-test}"

if [[ -z "$SUBSCRIPTION_ID" ]]; then
    if [[ ! -t 0 ]]; then
        echo "SUBSCRIPTION_ID is required: the Azure subscription UUID containing the VPN resource group." >&2
        exit 1
    fi
    printf '\nEnter the Azure subscription UUID containing the VPN resource group to delete.\n'
    printf 'Find it with: az account list --output table\n'
    printf 'Example: 00000000-0000-0000-0000-000000000000\n'
    while [[ -z "$SUBSCRIPTION_ID" ]]; do
        read -r -p "SUBSCRIPTION_ID: " SUBSCRIPTION_ID
    done
fi
command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) is required." >&2; exit 1; }
if ! az account show >/dev/null 2>&1; then
    az login
fi
az account set --subscription "$SUBSCRIPTION_ID"

if ! az group exists --name "$RESOURCE_GROUP" | grep -q true; then
    echo "Resource group $RESOURCE_GROUP does not exist. Nothing to remove."
    exit 0
fi

read -r -p "Delete resource group $RESOURCE_GROUP and all resources in it? [y/N] " answer
if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "Cancelled."
    exit 0
fi

az group delete --name "$RESOURCE_GROUP" --yes
printf 'Deleted %s. Local SSH and WireGuard key files were retained.\n' "$RESOURCE_GROUP"
