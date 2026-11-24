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

## Clean reinstall

From a trusted checkout:

```bash
bash zte-cli/reinstall.sh
```

The script downloads a fresh copy of this repository, checks Python syntax and runs available cache tests, backs up local `zte-cli.json` and `reports/` under `~/.local/share/zte-cli-backups/`, then replaces `~/.local/share/zte-cli/`. It never clears OLT settings. Review and restore any customized configuration from backup before connecting.

## Interactive batch planning and scoped removal

```text
reg all preview
reg all
reg GPON0047D8B8 preview
unreg 1/3/1 preview
unreg 1/3/1
unreg 1/3 preview
unreg 1/3
```

Registration plans are fully constructed and ONU IDs reserved before any provisioning commands are applied. The apply phase uses the stored per-ONU command plan, stopping on an unsuccessful ONU. Preview performs no provisioning changes.

`unreg` only targets registered ONU entries from matching `gpon-olt` interface blocks. It displays the targets and requires typing `DELETE <scope>` before changes. It rechecks each serial/ONU-ID mapping immediately before issuing `no onu <id>`. This is a destructive OLT operation: use preview first, and validate the deletion syntax on your C300 firmware before production use.

**Validation status:** The new planning, scoped deletion and reinstall changes require a local Python test run and a firmware-specific lab test. Do not use module-wide deletion on a production OLT before validation.

## Fast testing wrapper: `t`

Download the wrapper once, then use it for rapid reinstall/debug cycles:

```bash
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/tishriclarin/scripts-tools/main/zte-cli/t -o ~/.local/bin/t
chmod 700 ~/.local/bin/t
~/.local/bin/t
```

`t` downloads and executes the latest reinstall script, removes the old local installation and cache files, backs up configuration/reports, and launches the CLI on `192.168.10.60` with username `zte`. It prompts for the password without echoing it. Review the downloaded script before executing it on a production machine.

For an interactive read-only session: `~/.local/bin/t preview`. To skip reinstall for quick retesting: `~/.local/bin/t --no-install`.

For noninteractive test environments, `ZTE_CLI_PASSWORD` can be provided as a transient environment variable; avoid saving it in shell history or a file. The password is not stored in GitHub.

**Note:** A fresh reinstall replaces the local configuration with the repository default; backups are saved under `~/.local/share/zte-cli-backups`. The wrapper does not clear OLT configuration.
