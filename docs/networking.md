# Networking

## Refresh IP Address (pick up new DHCP/static assignment from router)

```bash
sudo nmcli con down netplan-eno1 && sudo nmcli con up netplan-eno1
```

> On Ubuntu with Netplan, connections are prefixed with `netplan-`. The interface `eno1` is the onboard ethernet NIC.

To find your connection name if it differs:

```bash
nmcli -f NAME,TYPE con show --active
```

## Check Current IP

```bash
ip addr show eno1
```

Or:

```bash
hostname -I
```
