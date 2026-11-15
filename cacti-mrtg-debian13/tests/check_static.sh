#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
for f in install_debian13.sh bin/cacti_account.sh bin/mrtg_private.sh; do
  bash -n "$f"
done
php -l bin/cacti_account.php
python3 - <<'PY'
from pathlib import Path
s=Path('bin/cacti_account.php').read_text()
for val in [
  "policy_graphs,policy_trees,policy_hosts,policy_graph_templates",
  "3,2,2,2,2,'on'",
  "['ifName', 'ifDescr', 'ifAlias', 'ifIndex']",
  "SELECT DISTINCT snmp_index FROM host_snmp_cache",
  "--snmp-field=ifIndex",
  "password_hash($pw, PASSWORD_DEFAULT)",
  "user_auth_perms (user_id,item_id,type) VALUES (?,?,1)",
  "UPDATE user_auth SET enabled='',locked='on'",
  "case 'audit-all'",
]:
    assert val in s,val
install=Path('install_debian13.sh').read_text()
assert 'disable --now mrtg.service' in install
assert 'LocationMatch "^/mrtg(?:/|$)"' in install
assert '/var/lib/mrtg-private' in install
print('PASS: static shell/PHP syntax and required security invariants present')
PY
