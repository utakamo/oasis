#!/bin/sh
set -e  # Exit immediately if a command fails

opkg update

# Download packages to /tmp
wget -O /tmp/oasis_3.1.2-r1_all.ipk https://github.com/utakamo/oasis/releases/download/v3.1.2/oasis_3.1.2-r1_all.ipk
wget -O /tmp/luci-app-oasis_3.1.2-r1_all.ipk https://github.com/utakamo/oasis/releases/download/v3.1.2/luci-app-oasis_3.1.2-r1_all.ipk
wget -O /tmp/oasis-mod-tool_1.0.4-r1_all.ipk https://github.com/utakamo/oasis/releases/download/v3.1.2/oasis-mod-tool_1.0.4-r1_all.ipk

# Install packages from /tmp
opkg install /tmp/oasis_3.1.2-r1_all.ipk
opkg install /tmp/luci-app-oasis_3.1.2-r1_all.ipk
opkg install /tmp/oasis-mod-tool_1.0.4-r1_all.ipk

# Verify installation
echo "Installed packages:"
opkg list-installed | grep -E 'oasis|luci-app-oasis|oasis-mod-tool'

# Clean up temporary files if no longer needed
rm -f /tmp/oasis_3.1.2-r1_all.ipk \
      /tmp/luci-app-oasis_3.1.2-r1_all.ipk \
      /tmp/oasis-mod-tool_1.0.4-r1_all.ipk

# Completion message
echo "Oasis installation completed successfully!"
echo "System Rebooting ..."
reboot
