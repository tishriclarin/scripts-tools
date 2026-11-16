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
  'cacti cacti/webserver select none' \
  'cacti cacti/dbconfig-install boolean true' | debconf-set-selections
apt-get update
# NGINX-only policy: preflight APT so no Apache dependency is installed.
packagelist='nginx mariadb-server dbconfig-common dbconfig-mysql php php8.4-fpm php8.4-cli php8.4-mysql php8.4-gd php8.4-snmp php8.4-xml php8.4-mbstring php8.4-intl php8.4-zip php8.4-gmp php8.4-ldap cacti mrtg snmp rrdtool iputils-ping cron'
apt-get -s install --no-install-recommends $packagelist > /tmp/scripts-tools-apt-plan
if grep -Eq '^Inst (apache2|apache2-bin|libapache2-mod-php)' /tmp/scripts-tools-apt-plan; then
    rm -f /tmp/scripts-tools-apt-plan
    echo 'APT would install Apache: refusing. Review dependency alternatives.' >&2; exit 1
fi
rm -f /tmp/scripts-tools-apt-plan
apt-get install -y --no-install-recommends $packagelist
systemctl enable --now php8.4-fpm
[[ -S /run/php/php8.4-fpm.sock ]] || { echo 'PHP 8.4-FPM socket missing' >&2; exit 1; }
[[ -f /usr/share/cacti/site/index.php ]] || { echo 'Cacti site files missing' >&2; exit 1; }

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
# NGINX serves only the Cacti directory, never MRTG output.
install -d -o root -g root -m 0755 /var/lib/scripts-tools/webroot /etc/nginx/snippets
[[ ! -e /var/lib/scripts-tools/webroot/cacti && ! -L /var/lib/scripts-tools/webroot/cacti ]] ||
  { echo 'Cacti webroot path already exists' >&2; exit 1; }
ln -s /usr/share/cacti/site /var/lib/scripts-tools/webroot/cacti
install -o root -g root -m 0644 "$here/examples/nginx-cacti-locations.conf" /etc/nginx/snippets/scripts-tools-cacti-locations.conf
install -o root -g root -m 0644 "$here/examples/nginx-cacti-local.conf" /etc/nginx/sites-available/scripts-tools-cacti-local.conf
# On a fresh NGINX install remove the default HTTP site symlink.
if [[ -L /etc/nginx/sites-enabled/default ]] && [[ "$(readlink -f /etc/nginx/sites-enabled/default)" == /etc/nginx/sites-available/default ]]; then
  rm /etc/nginx/sites-enabled/default
fi
ln -s /etc/nginx/sites-available/scripts-tools-cacti-local.conf /etc/nginx/sites-enabled/scripts-tools-cacti-local.conf
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
nginx -t
systemctl enable --now mariadb nginx cron
systemctl reload nginx
systemctl restart php8.4-fpm

echo
echo 'Debian 13 Cacti + MRTG base installation completed.'
echo 'Initial setup: ssh -L 8080:127.0.0.1:8080 USER@SERVER; open http://localhost:8080/cacti/'
echo 'NGINX initially listens only on 127.0.0.1:8080. Configure the example HTTPS virtual host and certificate before customer access.'
echo 'Set a new administrator password before customer onboarding:'
echo '  sudo cacti_account.sh reset-admin'
echo 'Use HTTPS with a trusted certificate before exposing Cacti to customers.'
echo 'MRTG workdir is /var/lib/mrtg-private (NOT in a web directory).'
echo 'Review README.md for SNMP device setup, Cacti poller and access tests.'
