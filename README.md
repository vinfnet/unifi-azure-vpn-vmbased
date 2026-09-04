# VM-based UniFi-to-Azure WireGuard VPN

Deploy a low-cost Ubuntu VM as a WireGuard gateway between a UniFi gateway and an Azure virtual network. The scripts create the resource group, VNet, subnet, NSG, static public IP, NIC, and VM; install WireGuard; and generate an importable UniFi VPN Client profile.

## Default topology

The defaults are examples and can be overridden with environment variables.

| Item | Default |
|---|---|
| Azure region | West Europe |
| Resource group | `unifi-azure-vpn-test` |
| Azure VNet | `10.240.20.0/24` |
| VM subnet | `10.240.20.0/27` |
| VM private/ping IP | `10.240.20.4` |
| VM size | `Standard_B1ls` |
| OS | Ubuntu Server 22.04 LTS |
| OS disk | 32 GiB Standard HDD LRS |
| WireGuard network | `172.31.254.0/30` |
| Azure WireGuard IP | `172.31.254.1` |
| UniFi WireGuard IP | `172.31.254.2` |
| Example UniFi LAN | `192.168.10.0/24` |
| WireGuard port | UDP 51820 |

The deployment checks the proposed Azure and WireGuard prefixes against every VNet prefix in the selected subscription and exits on overlap. It also checks both prefixes against `LAN_CIDR`.

## Security

- UDP 51820 is exposed for WireGuard.
- SSH is limited to the deployer's detected public `/32`, or `ADMIN_CIDR` when supplied.
- SSH uses a generated Ed25519 key rather than passwords.
- The generated UniFi private key is downloaded into `udm-wireguard.conf`, removed from the VM, and stored locally with mode 600.
- Generated keys and configuration are excluded by `.gitignore`.

Never publish `udm-wireguard.conf` or the `.ssh` directory.

## Prerequisites

- An Azure subscription and permission to create resource groups, networking, and VMs
- Azure CLI (`az`)
- OpenSSH (`ssh`, `scp`, and `ssh-keygen`)
- `curl`
- A UniFi Cloud Gateway or Next-Gen Gateway supporting WireGuard VPN Client

## Deploy

Make the scripts executable:

```shell
chmod +x deploy.sh configure-wireguard.sh destroy.sh
```

Run the deployment script:

```shell
./deploy.sh
```

It prompts, with descriptions and examples, for the two required values:

- `SUBSCRIPTION_ID`: the Azure subscription UUID where resources will be created.
- `LAN_CIDR`: the private LAN behind the UniFi gateway that must reach Azure.

Alternatively, provide both as environment variables for unattended deployment:

```shell
SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000" \
LAN_CIDR="192.168.10.0/24" \
./deploy.sh
```

If Azure CLI is not authenticated, the script invokes `az login`. It refuses to alter an existing resource group.

Common overrides:

```shell
SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000" \
RESOURCE_GROUP="my-unifi-vpn-test" \
LOCATION="uksouth" \
VNET_CIDR="10.241.0.0/24" \
SUBNET_CIDR="10.241.0.0/27" \
VM_PRIVATE_IP="10.241.0.4" \
LAN_CIDR="192.168.50.0/24" \
ADMIN_CIDR="203.0.113.10/32" \
./deploy.sh
```

Keep `VNET_CIDR`, `SUBNET_CIDR`, `VM_PRIVATE_IP`, `WG_CIDR`, `WG_SERVER_IP`, and `WG_UDM_IP` internally consistent when overriding them.

## Configure UniFi

UI labels vary by UniFi Network version.

1. Open **Settings > VPN > VPN Client**.
2. Create a WireGuard VPN Client and import the generated `udm-wireguard.conf`.
3. Name it **Azure WireGuard** and enable it. The client should become **Connected**.
4. Create a policy route. Imported VPN Client traffic is not selected automatically:
   - Network 9.4: **Settings > Policy Table > Create New Policy > Route**
   - Network 9.3: **Settings > Policy Engine > Policy-Based Routes > Create Route**
   - Interface: **Azure WireGuard**
   - Source: the UniFi LAN represented by `LAN_CIDR`
   - Destination: select **IP**, then **Add IP Address**
   - IP address: the value of `VM_PRIVATE_IP`
   - Port: blank
   - Kill switch: disabled for initial testing
5. Save/apply the route.
6. If the source LAN is isolated, add an allow rule from `LAN_CIDR` to `VNET_CIDR` before its deny rule.

To route the complete Azure network, use an IP range spanning the VNet or a CIDR if the installed UniFi Network version accepts CIDR input.

### Dual WAN

The WireGuard client normally follows the gateway's WAN routing:

- In failover mode it uses the primary WAN and re-establishes through the backup after failure.
- In load-balancing mode connection hashing selects a WAN and preserves session stickiness.
- The Azure NSG accepts WireGuard from any Internet source, and WireGuard learns the peer's latest endpoint, so either WAN works.

`PersistentKeepalive = 25` helps the tunnel recover after NAT changes or WAN failover. Do not route the Azure WireGuard server's public endpoint through the WireGuard client itself.

## Test and troubleshoot

From a workstation on `LAN_CIDR`, ping `VM_PRIVATE_IP`. The first packet may be lost while the tunnel establishes.

On the Azure VM:

```shell
sudo wg show
ip route
sudo systemctl status wg-quick@wg0
```

- No handshake: verify keys, endpoint, outbound UDP 51820, and the Azure NSG.
- Handshake but no ping: verify the mandatory UniFi policy route and LAN firewall rules.
- Ping reaches Azure but no reply: verify `AllowedIPs`, Linux routes, and reverse-path firewall rules.

## Estimated cost

Example pay-as-you-go pricing for West Europe in USD, checked in September 2026:

| Resource | Example rate | Approx. 730-hour month |
|---|---:|---:|
| `Standard_B1ls` Linux VM | $0.006/hour | $4.38 |
| Standard static IPv4 | $0.005/hour | $3.65 |
| 32 GiB Standard HDD LRS | $1.536/month | $1.54 |
| VNet, subnet, NIC, NSG | No base charge | $0.00 |
| **Estimated fixed total** | | **$9.57/month** |

Inbound transfer is free; outbound transfer may be billed. Prices vary by region, date, agreement, and currency. Check the [Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/) before deployment.

Deallocating the VM stops compute charges, but its disk and public IP continue billing. Delete the resource group when testing is complete.

## Remove

Run `./destroy.sh`. It prompts for the required Azure subscription UUID and asks for confirmation before deleting the default resource group.

Alternatively, use the same subscription and resource group values used for deployment as environment variables:

```shell
SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000" \
./destroy.sh
```

The local SSH key and UniFi profile are retained intentionally. Delete them securely and remove the VPN Client from UniFi when no longer needed.

## License

MIT
