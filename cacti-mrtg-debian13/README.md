# scripts-tools / cacti-mrtg-debian13

**Debian 13 (Trixie) · Cacti 1.2.30 · MRTG 2.17.10 · v0.1.0 (testing required)**

This toolset installs Cacti and optional PRIVATE MRTG collection on a fresh Debian 13 server. The Cacti customer portal assigns each local customer account **only its explicitly approved interface/VLAN traffic graphs**, instead of granting device-wide, tree-wide or template-wide access.

**Production caution:** This release has passed only shell/PHP syntax and basic static checks. Its real Cacti schema and cross-account web authorization behavior have **not** been validated on a Debian 13 deployment. Do not expose customer access without completing the acceptance tests below. Cacti's per-graph ACLs do not necessarily isolate all metadata and plugin endpoints; separate Cacti instances may be appropriate for high-assurance multi-tenancy.

## 1. Prerequisites

Use a clean Debian 13 VM with root/sudo, working package repositories, system time, DNS, and management-only connectivity to SNMP-capable network devices. Take a VM snapshot first. The installer refuses to overwrite an existing Cacti package.

Use read-only SNMPv3 authPriv whenever possible, and allow UDP 161 only from monitoring infrastructure. Do not expose MariaDB (3306), the SNMP management network, MRTG output, or default HTTP Cacti to the Internet.

## 2. Installation

From a Git checkout:

~~~bash
git clone https://github.com/tishriclarin/scripts-tools.git
cd scripts-tools/cacti-mrtg-debian13
sudo bash install_debian13.sh
sudo cacti_account.sh reset-admin
~~~

The script installs Apache, PHP, MariaDB, Cacti, RRDTool, SNMP, MRTG and Debian dbconfig-common. It uses the Debian package defaults for database/template setup, disables anonymous Cacti guest access, installs the account management scripts, disables the stock MRTG service and creates a root-only private MRTG collector directory at **/var/lib/mrtg-private**.

Remote HTTP to the Cacti path is blocked. For initial setup, open a tunnel from your workstation:

~~~bash
ssh -L 8080:127.0.0.1:80 admin@MONITORING_SERVER
~~~

Then open **http://localhost:8080/cacti/**. For clients, configure Apache TLS using a valid certificate and use **https://monitor.example.com/cacti/**. The sample access rule only permits remote Cacti access when *Apache itself* handles HTTPS. If terminating TLS at a proxy, review and deliberately configure TLS forwarding/ACLs; never publish passwords over plaintext HTTP.

## 3. Add monitored devices in Cacti

In **Cacti Console → Management → Devices**, add the router, switch or OLT and its management address and read-only SNMP credentials. Add the **SNMP - Interface Statistics** data query to that device. Verify a successful verbose query and re-index the interface list.

For an SNMPv2c lab only (the community appears in shell arguments; prefer the UI and SNMPv3 in production):

~~~bash
sudo php /usr/share/cacti/cli/add_device.php --description='LAB-SW' --ip=192.0.2.10 --template=1 --version=2 --community='CHANGE-ME-READONLY'
sudo php /usr/share/cacti/cli/add_graphs.php --list-hosts
~~~

Check the actual local host template ID; **1 is only an example**. Use the proper device SNMP query rather than assuming the interface table is ready.

### Interface and VLAN counters

A physical interface/subinterface or device VLAN interface can be graphed if the device exposes 64-bit interface counters: **ifHCInOctets** and **ifHCOutOctets**. A VLAN tag on an Ethernet trunk is *not*, on its own, a separate counter. For per-customer VLAN graphs, verify a real VLAN subinterface, SVI, ONU service counter, or vendor-specific MIB/template rather than mislabeling the whole trunk as that customer's traffic.

## 4. Discover Cacti IDs/interfaces

~~~bash
sudo cacti_account.sh devices
sudo cacti_account.sh interfaces 5
~~~

Example (illustrative only):

~~~text
12   ether1    ether1   Client-A-Uplink
35   vlan100   vlan100  Client-A-VLAN100
38   vlan200   vlan200  Client-B-VLAN200
~~~

Cacti device ID 5 in these examples is **not an IP address**; substitute a discovered Cacti device ID.

## 5. Provision isolated customer graphs/accounts

~~~bash
sudo cacti_account.sh add client_a - '5:ifName:ether1' '5:ifName:vlan100'
sudo cacti_account.sh add client_b - '5:ifName:vlan200'
~~~

The hyphen prompts for a hidden password. Passwords must be 12–128 bytes. The requested positional password form is also accepted:

~~~bash
sudo cacti_account.sh add client_a 'A-Strong-Passphrase-Here' '5:ifName:vlan100'
~~~

But **avoid password command-line arguments**: they can leak in shell history and process listings.

Exact interface selector forms:

| Selector | Description |
| --- | --- |
| 5:ifName:vlan100 | SNMP ifName equals vlan100 |
| 5:ifDescr:Vlan100 | SNMP ifDescr equals Vlan100 |
| 5:ifAlias:Client-A | SNMP ifAlias equals Client-A, only if unique |
| 5:ifIndex:35 | SNMP ifIndex is 35 |
| 5:vlan100 | Shorthand for 5:ifName:vlan100 |

Account creation verifies the device, SNMP interface query, unambiguous interface identity and 64-bit template. It creates a graph using Cacti's bundled add_graphs.php if necessary, creates a local graph-only Cacti user, sets **deny by default** for graph, tree, device and template policy, and grants only the selected graph IDs. It refuses to reuse an existing username or share the same graph between active script-managed customer accounts.

First Cacti graph points typically take multiple polling cycles. Verify poller health if RRD data is NaN.

## 6. List, inspect, audit and remove accounts

~~~bash
sudo cacti_account.sh list
sudo cacti_account.sh show client_a
sudo cacti_account.sh audit client_a
sudo cacti_account.sh audit-all
sudo cacti_account.sh remove client_a
~~~

**remove** disables the managed login and revokes its graph, realm and group grants and remember-me tokens. It leaves historical graph/RRD data untouched and retains the disabled user row for auditing. Existing browser sessions may remain active until session expiry; for immediate revocation, invalidate the application's sessions as appropriate.

**audit-all** verifies deny-by-default policies, graph-only realm, no group memberships, no broad graph/device/template/tree grants, and no duplicate active customer graph assignments. Treat a failed audit as a release blocker.

## 7. Optional MRTG (administrator only)

Cacti is the customer-facing dashboard; MRTG is independent and **must not** be publicly served.

~~~bash
sudo mrtg_private.sh add vlan100 192.0.2.1 35 125000000
sudo mrtg_private.sh list
sudo mrtg /etc/mrtg/scripts-tools/private.cfg
~~~

The MRTG helper prompts for a read-only SNMPv2c community and configures 64-bit counters. MaxBytes of 125000000 is an *example* for a 1 Gbps link (bytes per second). Prefer SNMPv3 for production; configure authenticated MRTG targets in the root-owned file when available. The private cron entry polls every five minutes once targets.cfg exists.

**Never** symlink /var/lib/mrtg-private or /etc/mrtg/scripts-tools into /var/www, Cacti, a web server alias, a proxy cache, or CDN. MRTG's generated PNGs/HTML do not check Cacti user permissions.

## 8. Mandatory two-customer access tests

1. On a disposable SNMP target with two separately counted interfaces/VLAN interfaces, create **client_a** assigned to X and **client_b** assigned to Y. Run **sudo cacti_account.sh audit-all**.
2. Log in as A using a fresh browser session. Confirm its Graphs/Preview shows X but not Y. Record actual graph IDs using the show command.
3. Still logged in as A, attempt to fetch B's graph using the direct graph image endpoint, e.g. **/cacti/graph_image.php?local_graph_id=B_GRAPH_ID**. The response must not disclose B's graph. Also test graph detail/export endpoints, plugins and APIs enabled on the server.
4. Reverse the test: B must not see or fetch A's graph. Check graphs, previews, any user-facing device names and metadata.
5. Remove A and test both fresh login (must fail) and any existing A session (must not disclose protected data); B must remain functional.
6. Review Apache aliases and any CDN/reverse-proxy caches. Confirm there is **no** web path for MRTG output.

**Do not roll out customer access before these tests pass.** Cacti's graph permissions may not provide comprehensive tenant isolation from all device descriptions, plugin data, APIs or cached graph responses. Use separate Cacti instances for isolation-sensitive customers.

## 9. Operations

~~~bash
bash tests/check_static.sh
sudo bash tests/server_health.sh
sudo cacti_account.sh audit-all
sudo systemctl status apache2 mariadb cron
sudo tail -n 50 /var/log/cacti/cacti.log
~~~

Keep a single Cacti poller schedule; Debian's package manages polling and this installer does not add a second Cacti poller. Regularly patch Cacti, back up MariaDB/RRD data, protect credentials, and verify graph identity following router/OLT interface index changes.

## 10. Files

~~~text
cacti-mrtg-debian13/
├── install_debian13.sh       # Fresh Debian 13 installer
├── bin/
│   ├── cacti_account.sh     # Account management entry point
│   ├── cacti_account.php    # Graph CLI, DB permissions and audit
│   └── mrtg_private.sh      # Root-only MRTG target helper
├── examples/private.cfg     # Optional private MRTG config
├── tests/
│   ├── check_static.sh      # Shell/PHP and guard checks
│   └── server_health.sh     # Post-install health checks
├── VERSION
└── README.md
~~~

**Compatibility:** Assumes Debian 13's Cacti 1.2.30 schema and bundled data-query names. Validate against the actual package after security updates or upgrades. The scripts have not been run on the user's production server.

## Official references

- Debian Cacti: https://packages.debian.org/trixie/cacti
- Debian Cacti postinst: https://sources.debian.org/src/cacti/1.2.30%2Bds1-1/debian/cacti.postinst/
- Cacti schema: https://sources.debian.org/src/cacti/1.2.30%2Bds1-1/cacti.sql
- Cacti CLI documentation: https://github.com/Cacti/documentation/blob/develop/Command-Line-Scripts.md
- Cacti user management: https://github.com/Cacti/documentation/blob/develop/User-Management.md
- MRTG reference: https://oss.oetiker.ch/mrtg/doc/mrtg-reference.en.html
