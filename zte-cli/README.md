# ZTE-CLI 2.0 — C300 provisioning candidate

Derived from the supplied `zte-cli-v1.3.zip`. Python 3.10+; no third-party packages.

## Run

```bash
python3 -m unittest -v test_cache
python3 zte_cli.py preview --host 192.0.2.10 --user admin --config zte-cli.json
python3 zte_cli.py --host 192.0.2.10 --user admin --config zte-cli.json
```

Inside the shell: `show cache`, `show unreg`, `reg all`, `reg <serial>`, `refresh`, `exit`.

## Configuration cache

On refresh and before each registration batch, fetch running config once and cache in source order:
- ONU types from existing `onu <id> type <name> sn <serial>` and type definitions.
- VLAN profile definitions from `vlan-profile <name>`.
- Traffic profiles from existing `traffic-profile <name> vport <n> direction ingress|egress` assignments.
- Per-PON interface descriptions and NIDS metadata.

The first discovered value is the fallback. Explicit NIDS `VLAN-PROFILE`, `ONU-TYPE`/`TYPE`, `TRAFFIC-INGRESS`, and `TRAFFIC-EGRESS` override it. Unknown explicit values fail rather than silently falling back. NIDS `VLAN:150` or `VLAN:VLAN150` supplies service VLAN; otherwise set `pon_service_vlans` in JSON. No service VLAN is guessed.

## Safety and limitations

- **This is an offline-tested candidate, not a firmware-validated production release.** The existing 1.3 command template and verification regexes remain and need checking against actual OLT outputs.
- `reg all` applies configuration without per-ONU confirmation. Use `preview` and one-ONU testing first.
- Telnet credentials and session traffic are unencrypted: use an isolated management network.
- WAN DHCP is **disabled** by default because its firmware-specific command/context and readiness sequence have not been validated. After validating, enable `enable_wan_dhcp` and customize `wan_commands`; add matching WAN verification checks before production use.
- The configured verification checks govern success. Saving occurs after all checks pass; failures after partial writes are marked `PARTIAL` and are not rolled back automatically.
- `show cache` displays the snapshot. `refresh` rebuilds it. Configuration changes from other operators during a batch are not detected.
- Validate actual ONU readiness, VLAN profile definitions, profile compatibility, command error patterns, Telnet prompt/pagination handling, and `write` semantics on your firmware before deployment.