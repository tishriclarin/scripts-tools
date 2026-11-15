#!/usr/bin/env bash
# Fresh Debian 13 server installer for scripts-tools customer-portal Cacti and private MRTG.
set -euo pipefail
umask 077
here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ "$EUID" -eq 0 ]] || { echo 'Run as root: sudo bash install_debian13.sh' >&2; exit 1; }
. /etc/os-release
[[ "$ID" == debian && "$VERSION_ID" == 13* ]] || { echo 'This installer supports a fresh Debian 13 (trixie) only.' >&2; exit 1; }
if dpkg-query -W -f='${Status}' cacti 2>/dev/null | grep -q 'install ok installed'; then
    echo 'Existing Cacti detected. Installer refuses to modify an existing deployment.' >&2
    echo 'Follow README.md manual integration/backup procedure instead.' >&2
    exit 1
fi
if [[ ! -f "$here/bin/cacti_account.php" || ! -f "$here/bin/cacti_account.sh" ]]; then
    echo 'Installer must be run from extracted scripts-tools package.' >&2; exit 1
fi
export DEBIAN_FRONTEND=noninteractive
# Debian's cacti postinst provisions database, admin and import templates via dbconfig-common.
printf '%s\n' \
  'cacti cacti/webserver select apache2' \
  'cacti cacti/dbconfig-install boolean true' | debconf-set-selections
apt-get update
apt-get install -y --no-install-recommends \
  apache2 mariadb-server dbconfig-common dbconfig-mysql \
  libapache2-mod-php php-cli php-mysql php-gd php-snmp php-xml php-mbstring php-intl php-zip \
  cacti mrtg snmp rrdtool iputils-ping cron

if [[ ! -f /etc/cacti/debian.php ]]; then
    echo 'ERROR: Cacti dbconfig-common was not configured; check dpkg-reconfigure cacti.' >&2
    exit 1
fi
if [[ ! -f /usr/share/cacti/cli/add_graphs.php ]]; then
    echo 'ERROR: Missing Cacti CLI binaries.' >&2; exit 1
fi
install -d -o root -g root -m 0700 /usr/local/lib/scripts-tools
install -o root -g root -m 0700 "$here/bin/cacti_account.sh" /usr/local/sbin/cacti_account.sh
install -o root -g root -m 0600 "$here/bin/cacti_account.php" /usr/local/lib/scripts-tools/cacti_account.php
install -o root -g root -m 0700 "$here/bin/mrtg_private.sh" /usr/local/sbin/mrtg_private.sh
install -d -o root -g root -m 0700 /var/lib/mrtg-private /etc/mrtg/scripts-tools
install -o root -g root -m 0600 "$here/examples/private.cfg" /etc/mrtg/scripts-tools/private.cfg

# The stock MRTG service may use /etc/mrtg/mrtg.cfg and serve PNGs outside Cacti ACLs.
# Disable it; configure ONLY our root-owned private collector through cron.
systemctl disable --now mrtg.service 2>/dev/null || true
if [[ -f /etc/cron.d/mrtg ]]; then
    mv -n /etc/cron.d/mrtg /etc/cron.d/mrtg.disabled
fi
# These paths are not served, even if an administrator later enables MRTG Apache config.
a2disconf mrtg 2>/dev/null || true
cat >/etc/apache2/conf-available/scripts-tools-mrtg-deny.conf <<'EOF'
<LocationMatch "^/mrtg(?:/|$)">
    Require all denied
</LocationMatch>
EOF
a2enconf scripts-tools-mrtg-deny >/dev/null
# Cacti is only remotely reachable when Apache itself terminates HTTPS.
# HTTP is local-only for initial setup (use an SSH local port forward).
cat >/etc/apache2/conf-available/scripts-tools-cacti-tls.conf <<'EOF'
<LocationMatch "^/cacti(?:/|$)">
    <RequireAny>
        Require local
        Require expr "%{HTTPS} == 'on'"
    </RequireAny>
</LocationMatch>
EOF
a2enconf scripts-tools-cacti-tls >/dev/null
# Use a cron job only when targets have been configured.
cat >/etc/cron.d/scripts-tools-mrtg <<'EOF'
*/5 * * * * root test -s /etc/mrtg/scripts-tools/targets.cfg && /usr/bin/mrtg /etc/mrtg/scripts-tools/private.cfg --logging /var/log/scripts-tools-mrtg.log
EOF
chmod 0644 /etc/cron.d/scripts-tools-mrtg
cat >/etc/logrotate.d/scripts-tools-mrtg <<'EOF'
/var/log/scripts-tools-mrtg.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    copytruncate
}
EOF

# Disable Cacti guest/anonymous use, but leave all other stock Cacti defaults alone.
php /usr/local/lib/scripts-tools/cacti_account.php lockdown
apache2ctl configtest
systemctl enable --now mariadb apache2 cron
systemctl reload apache2

echo
echo 'Debian 13 Cacti + MRTG base installation completed.'
echo 'Initial setup: SSH tunnel to server: sudo ssh -L 8080:127.0.0.1:80 USER@SERVER; open http://localhost:8080/cacti/'
echo 'Remote customer access is blocked until Apache HTTPS is configured with a valid certificate.'
echo 'Set a new administrator password before customer onboarding:'
echo '  sudo cacti_account.sh reset-admin'
echo 'Use HTTPS with a trusted certificate before exposing Cacti to customers.'
echo 'MRTG workdir is /var/lib/mrtg-private (NOT in a web directory).'
echo 'Review README.md for SNMP device setup, Cacti poller and access tests.'
