#!/bin/sh
set -e  # Exit immediately if a command fails

OASIS_VER="${OASIS_VER:-3.2.0-r1}"
LUCI_VER="${LUCI_VER:-3.2.0-r1}"
TOOL_VER="${TOOL_VER:-1.0.4-r1}"
RELEASE_TAG="${RELEASE_TAG:-v3.2.0}"

BASE_URL="https://github.com/utakamo/oasis/releases/download/${RELEASE_TAG}"

OASIS_IPK="oasis_${OASIS_VER}_all.ipk"
LUCI_IPK="luci-app-oasis_${LUCI_VER}_all.ipk"
TOOL_IPK="oasis-mod-tool_${TOOL_VER}_all.ipk"

opkg update

# Download packages to /tmp
wget -O "/tmp/${OASIS_IPK}" "${BASE_URL}/${OASIS_IPK}"
wget -O "/tmp/${LUCI_IPK}" "${BASE_URL}/${LUCI_IPK}"
wget -O "/tmp/${TOOL_IPK}" "${BASE_URL}/${TOOL_IPK}"

# Install packages from /tmp
opkg install "/tmp/${OASIS_IPK}"
opkg install "/tmp/${LUCI_IPK}"
opkg install "/tmp/${TOOL_IPK}"

# Verify installation
echo "Installed packages:"
opkg list-installed | grep -E 'oasis|luci-app-oasis|oasis-mod-tool'

# Clean up temporary files if no longer needed
rm -f "/tmp/${OASIS_IPK}" \
      "/tmp/${LUCI_IPK}" \
      "/tmp/${TOOL_IPK}"

# Completion message
echo "System Rebooting ..."
reboot
