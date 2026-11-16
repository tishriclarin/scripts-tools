# scripts-tools

![scripts-tools banner](assets/scripts-tools-banner.svg)

**Reusable scripts and tools for network operations, Linux systems, automation, and infrastructure.**

**Web server standard: NGINX only** (PHP apps use PHP-FPM). See [CONTRIBUTING.md](CONTRIBUTING.md).

This repository is a collection of independent toolsets. It is **not** a Cacti-only repository: each tool lives in its own directory with its own installation guide, dependencies, tests, and versioning.

## Tool catalog

| Toolset | Platform | Purpose | Status |
| --- | --- | --- | --- |
| [Cacti + MRTG monitoring](cacti-mrtg-debian13/) | Debian 13 | Install Cacti/MRTG, graph SNMP interfaces or VLAN interfaces, and provision customer graph-only accounts | v0.1.0 — **test before production** |

Other network, server, scripting, and administrative utilities will be added as separate directories.

## Cacti + MRTG quick start

On a clean Debian 13 host:

```bash
sudo bash cacti-mrtg-debian13/install_debian13.sh
sudo cacti_account.sh devices
sudo cacti_account.sh interfaces 5
sudo cacti_account.sh add client_a - '5:ifName:vlan100'
sudo cacti_account.sh audit-all
sudo cacti_account.sh remove client_a
```

The `-` option prompts for a password rather than exposing it in command-line arguments. Devices and the SNMP interface data query must first be added in Cacti. VLAN graphs require device-exported counters; merely tagging a VLAN on a trunk does not create separate counters.

**Security:** customer access is deny-by-default and individual graph grants are provisioned by script, but live cross-account access and image-endpoint tests have **not** been completed. Do not expose the service to customers until you run the [mandatory acceptance tests](cacti-mrtg-debian13/README.md). Private MRTG output is not web-served. Review [SECURITY.md](SECURITY.md).

## Contributing a new tool

Give each tool a standalone directory with a `README.md`, installation instructions, dependency list, and a `tests/` folder where practical. Do not commit passwords, tokens, SNMP communities, production databases, or customer data.

## Validation

```bash
bash cacti-mrtg-debian13/tests/check_static.sh
```

GitHub Actions performs syntax and static checks. These checks do **not** replace live integration or multi-tenant security testing.

## License

No license is granted yet; contact the repository owner before redistribution.
