#!/bin/sh
set -e

RELEASE_TAG="${RELEASE_TAG:-}"
OASIS_VER="${OASIS_VER:-}"
LUCI_VER="${LUCI_VER:-}"
TOOL_VER="${TOOL_VER:-}"
REBOOT="${REBOOT:-}"

API_URL="https://api.github.com/repos/utakamo/oasis/releases/latest"
TMP_DIR="/tmp"
BACKUP_FILE="/tmp/oasis/backup"

#------------------------------------------------------------
# File download function
#------------------------------------------------------------
dl() {
  if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -O "$1" "$2"
  else
    wget -O "$1" "$2"
  fi
}

#------------------------------------------------------------
# Get installed version
#------------------------------------------------------------
get_installed_ver() {
  opkg status "$1" 2>/dev/null | awk -F': ' '/^Version:/ {print $2; exit}'
}

#------------------------------------------------------------
# Get latest release information from GitHub API
#------------------------------------------------------------
get_latest_info_from_github() {
  tmp_json="${TMP_DIR}/oasis_latest.json"
  dl "$tmp_json" "$API_URL"
  RELEASE_TAG="${RELEASE_TAG:-$(grep -m1 '"tag_name"' "$tmp_json" | sed -E 's/.*"tag_name" *: *"([^"]+)".*/\1/')}"

  OASIS_VER="${OASIS_VER:-$(grep -o 'oasis_[0-9][^_]*_all.ipk' "$tmp_json" | head -n1 | sed -E 's/oasis_([^_]+)_all.ipk/\1/')}"
  LUCI_VER="${LUCI_VER:-$(grep -o 'luci-app-oasis_[0-9][^_]*_all.ipk' "$tmp_json" | head -n1 | sed -E 's/luci-app-oasis_([^_]+)_all.ipk/\1/')}"
  TOOL_VER="${TOOL_VER:-$(grep -o 'oasis-mod-tool_[0-9][^_]*_all.ipk' "$tmp_json" | head -n1 | sed -E 's/oasis-mod-tool_([^_]+)_all.ipk/\1/')}"
}

#------------------------------------------------------------
# Version comparison (opkg compare-versions + fallback)
#------------------------------------------------------------
compare_lt() {
  # On newer opkg environments use it directly
  if opkg compare-versions "$1" lt "$2" 2>/dev/null; then
    return 0
  # On older environments compare with sort -V
  elif [ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -n1)" != "$2" ]; then
    return 0
  else
    return 1
  fi
}

#------------------------------------------------------------
# Backup/restore configuration
#------------------------------------------------------------
backup_cfg() {
  mkdir -p "$(dirname "$BACKUP_FILE")"
  uci export oasis > "$BACKUP_FILE" 2>/dev/null || true
}

restore_cfg() {
  [ -f "$BACKUP_FILE" ] && uci -f "$BACKUP_FILE" import oasis || true
}

#------------------------------------------------------------
# Restart services
#------------------------------------------------------------
restart_services() {
  /etc/init.d/olt_tool restart 2>/dev/null || true
  /etc/init.d/rpcd restart 2>/dev/null || true
}

#------------------------------------------------------------
# Reboot prompt
#------------------------------------------------------------
prompt_reboot_if_needed() {
  if [ "$REBOOT" = "1" ] || [ "$REBOOT" = "true" ]; then
    echo "System Rebooting ..."
    reboot
  elif [ -z "$REBOOT" ]; then
    printf "Reboot now? [y/N]: "
    read ans
    case "$ans" in
      y|Y|yes|YES|Yes)
        echo "System Rebooting ..."
        reboot
        ;;
      *) echo "Skipping reboot." ;;
    esac
  else
    echo "Skipping reboot. REBOOT=$REBOOT"
  fi
}

#------------------------------------------------------------
# Main process
#------------------------------------------------------------
main() {
  opkg update

  cur_ver="$(get_installed_ver oasis || true)"
  echo "Current oasis version: ${cur_ver:-<not installed>}"

  if [ -z "$RELEASE_TAG" ] || [ -z "$OASIS_VER" ] || [ -z "$LUCI_VER" ] || [ -z "$TOOL_VER" ]; then
    echo "Fetching latest release info from GitHub..."
    if ! get_latest_info_from_github; then
      echo "Failed to fetch GitHub info. Ensure RELEASE_TAG,OASIS_VER,LUCI_VER,TOOL_VER are set."
      exit 1
    fi
  fi

  echo "Latest: tag=$RELEASE_TAG oasis=$OASIS_VER luci=$LUCI_VER tool=$TOOL_VER"

  cur_oasis="$(get_installed_ver oasis || true)"
  cur_luci="$(get_installed_ver luci-app-oasis || true)"
  cur_tool="$(get_installed_ver oasis-mod-tool || true)"
  echo "Current: oasis=${cur_oasis:-<not installed>} luci=${cur_luci:-<not installed>} tool=${cur_tool:-<not installed>}"

  need_upgrade=0

  # If package is not installed, mark upgrade required
  [ -z "$cur_oasis" ] && need_upgrade=1
  [ -z "$cur_luci" ] && need_upgrade=1
  [ -z "$cur_tool" ] && need_upgrade=1

  # Upgrade when existing versions are older
  if [ $need_upgrade -eq 0 ]; then
    if compare_lt "$cur_oasis" "$OASIS_VER"; then need_upgrade=1; fi
    if compare_lt "$cur_luci" "$LUCI_VER"; then need_upgrade=1; fi
    if compare_lt "$cur_tool" "$TOOL_VER"; then need_upgrade=1; fi
  fi

  if [ $need_upgrade -eq 0 ]; then
    echo "Already up-to-date. No upgrade."
    exit 0
  else
    echo "Upgrade required."
  fi

  BASE_URL="https://github.com/utakamo/oasis/releases/download/${RELEASE_TAG}"
  OASIS_IPK="oasis_${OASIS_VER}_all.ipk"
  LUCI_IPK="luci-app-oasis_${LUCI_VER}_all.ipk"
  TOOL_IPK="oasis-mod-tool_${TOOL_VER}_all.ipk"

  echo "Backing up configuration..."
  backup_cfg

  echo "Removing old packages..."
  opkg remove luci-app-oasis || true
  opkg remove oasis-mod-tool || true
  opkg remove oasis || true

  echo "Downloading packages..."
  dl "${TMP_DIR}/${OASIS_IPK}" "${BASE_URL}/${OASIS_IPK}"
  dl "${TMP_DIR}/${LUCI_IPK}" "${BASE_URL}/${LUCI_IPK}"
  dl "${TMP_DIR}/${TOOL_IPK}" "${BASE_URL}/${TOOL_IPK}"

  echo "Installing new packages..."
  opkg install "${TMP_DIR}/${OASIS_IPK}"
  opkg install "${TMP_DIR}/${LUCI_IPK}"
  opkg install "${TMP_DIR}/${TOOL_IPK}"

  echo "Restoring configuration..."
  restore_cfg

  echo "Cleaning up..."
  rm -f "${TMP_DIR}/${OASIS_IPK}" "${TMP_DIR}/${LUCI_IPK}" "${TMP_DIR}/${TOOL_IPK}"

  echo "Restarting services..."
  restart_services

  echo "Upgrade completed successfully!"
}

main "$@"
