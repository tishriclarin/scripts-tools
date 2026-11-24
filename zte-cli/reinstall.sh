#!/usr/bin/env bash
set -Eeuo pipefail
# Clean local ZTE-CLI installation only. Never modifies OLT configuration.
REPO_URL="https://github.com/tishriclarin/scripts-tools.git"
INSTALL_DIR="${ZTE_CLI_HOME:-$HOME/.local/share/zte-cli}"
BIN_DIR="${HOME}/.local/bin"
BACKUP_DIR="${HOME}/.local/share/zte-cli-backups"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
command -v git >/dev/null || { echo "git required"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required"; exit 1; }
case "$INSTALL_DIR" in ""|"/"|"$HOME"|"$HOME/"|"$BIN_DIR"|"$BACKUP_DIR") echo "Unsafe installation path"; exit 1;; esac
mkdir -p "$BIN_DIR" "$BACKUP_DIR"
echo "Fetching fresh ZTE-CLI source..."
git clone --depth 1 "$REPO_URL" "$WORK/repo"
SOURCE="$WORK/repo/zte-cli"
python3 -m py_compile "$SOURCE/zte_cli.py"
if [[ -f "$SOURCE/test_cache.py" ]]; then
  (cd "$SOURCE" && python3 -m unittest -v test_cache)
fi
if [[ -d "$INSTALL_DIR" ]]; then
  STAMP="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR/$STAMP"
  # Preserve local settings and reports before replacing program files.
  for item in zte-cli.json reports; do
    [[ ! -e "$INSTALL_DIR/$item" ]] || cp -a "$INSTALL_DIR/$item" "$BACKUP_DIR/$STAMP/"
  done
  rm -rf -- "$INSTALL_DIR"
fi
mkdir -p "$INSTALL_DIR"
cp -a "$SOURCE/." "$INSTALL_DIR/"
cat > "$BIN_DIR/zte-cli" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cd "${ZTE_CLI_HOME:-$HOME/.local/share/zte-cli}"
exec python3 zte_cli.py "$@"
EOF
chmod +x "$BIN_DIR/zte-cli"
echo "Installed: $INSTALL_DIR"
echo "Backups: $BACKUP_DIR"
echo "Run: $BIN_DIR/zte-cli --host <OLT-IP> --user <USER>"
