zte-cli v1.3: updated default provisioning template to match supplied C300 example.
Configure pon_service_vlans in zte-cli.json for each PON before applying.
Example: "pon_service_vlans": {"1/3/1": 150, "1/3/2": 151}
If no mapping exists, default service_vlan=150 is used: change this before production use.
Normal mode applies changes; preview mode displays commands.
The C300 firmware may reject individual commands: always preview and test one ONU.
No shutdown/linktrap/storm-control changes are generated; these are existing PON-level settings.