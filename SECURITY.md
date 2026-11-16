# Security notes

This repository contains network administration scripts, including an authentication-sensitive monitoring toolset.

- **Not production-validated:** Static checks are not deployment tests. Test Cacti permissions, direct graph images, graph previews, endpoints, plugins, browser sessions and cached permissions with two different customer accounts on an isolated Debian 13 test machine.
- **Confidentiality:** Keep administrator-only MRTG data outside all NGINX or reverse-proxy document roots. Do not expose MRTG-generated files in a publicly served directory.
- **Network:** Restrict SNMP to authorized management systems; prefer SNMPv3 authPriv over SNMPv2c, and use VPNs/ACLs.
- **Credentials:** Prefer the interactive password prompt in the account script. Never commit live credentials, passwords, database dumps or monitoring customer data.
- **Changes:** Snapshot the server, validate the package's version assumptions, and complete HTTPS configuration before onboarding customers.

For sensitive security reports, contact the repository owner privately instead of disclosing customer information in public issues.
