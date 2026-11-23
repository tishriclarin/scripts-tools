# MikroTik RouterOS: DDNS remote management

**File:** [remote-mgmt-ddns.rsc](remote-mgmt-ddns.rsc)

This RouterOS 7 script adds `tcc.cloud-ip.cc` to the `REMOTE-MGMT` firewall address list, creates an **input** allow rule for TCP **22 (SSH)** and **8291 (WinBox)** from that list, and sets **IP → Services → Available From** for both services to `0.0.0.0/0`. The script checks before adding the address-list entry or firewall rule, so repeated imports will not duplicate them.

## Install

1. Open MikroTik terminal using a **trusted local connection** and enable **Safe Mode** (`Ctrl+X`). Make a configuration backup.
2. Review your **input** firewall rules, management ports, IPv4/IPv6 policy, and rule order before installing. The script inserts the new allow rule at the top.
3. Upload `remote-mgmt-ddns.rsc` to the router's Files (or paste the file content into its terminal).
4. Run:

   ```routeros
   /import file-name=remote-mgmt-ddns.rsc
   ```

5. Confirm WinBox/SSH access from `tcc.cloud-ip.cc` and verify the intended non-allowed sources are denied before exiting Safe Mode.

## Verification

```routeros
/ip firewall address-list print detail where list="REMOTE-MGMT"
/ip firewall filter print detail where comment="ALLOW REMOTE-MGMT SSH WINBOX"
/ip service print detail where name="winbox" or name="ssh"
/ip firewall filter print detail where chain=input
```

## DNS and security behavior

- RouterOS resolves an FQDN used in an IP firewall address list and manages its dynamic resolved-IP entries with DNS caching and TTL. No separate 60-second scheduler is necessary for the **firewall address list**. A DNS TTL of 60 seconds does **not** guarantee a changed client IP becomes usable in exactly 60 seconds.
- `/ip service address=0.0.0.0/0` means the SSH/WinBox service layer accepts connections from **any IPv4 source**. The address-list **allow rule alone does not block others**.
- **Critical:** retain or add correctly ordered **input drop rules** denying unauthorized WAN management connections. Existing broad allow rules can override the intention. Avoid adding a blanket drop rule until trusted LAN, VPN, and emergency management paths have been accounted for.
- If SSH or WinBox run on custom ports, adjust the filter rule to match. This file intentionally uses ports 22 and 8291.
- This script does not configure IPv6 firewall or IPv6 service restrictions; audit `/ipv6 firewall` separately.
- DNS outages or stale TTL/cache entries can temporarily affect reachability. Maintain alternative management access.
- The script does **not** install the earlier optional service-IP synchronization scheduler, because the specified `0.0.0.0/0` service configuration makes that synchronization unnecessary.

Official docs: [MikroTik Address-lists](https://help.mikrotik.com/docs/spaces/ROS/pages/130220135/Address-lists), [IP Services](https://help.mikrotik.com/docs/spaces/ROS/pages/103841820/Services).
