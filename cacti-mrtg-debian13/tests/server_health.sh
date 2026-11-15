#!/usr/bin/env bash
set -euo pipefail
[[ "$EUID" -eq 0 ]] || { echo 'Use sudo/root' >&2; exit 1; }
[[ -f /etc/cacti/debian.php ]] || { echo 'Missing Cacti database config' >&2; exit 1; }
for bin in php mrtg snmpwalk apache2ctl; do command -v "$bin" >/dev/null || { echo "Missing $bin" >&2; exit 1; }; done
php /usr/share/cacti/cli/add_graphs.php --list-hosts >/dev/null
/usr/local/sbin/cacti_account.sh audit-all
apache2ctl configtest
[[ -d /var/lib/mrtg-private ]] || exit 1
[[ $(stat -c %a /var/lib/mrtg-private) == 700 ]] || { echo 'MRTG workdir is not root-only' >&2; exit 1; }
[[ ! -e /etc/apache2/conf-enabled/mrtg.conf ]] || { echo 'Public MRTG Apache config enabled' >&2; exit 1; }
echo 'PASS: Cacti CLI reachable, account ACL audit clean, Apache config syntactically valid, MRTG dir private.'
echo 'NEXT: complete manual two-customer HTTP(S) authorization acceptance test in README.md.'
