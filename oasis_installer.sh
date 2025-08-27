#!/bin/sh
set -e  # Exit immediately if a command fails

opkg update

# Download packages to /tmp
wget -O /tmp/oasis_3.0.0-r1_all.ipk https://github.com/utakamo/oasis/releases/download/v3.0.0/oasis_3.0.0-r1_all.ipk
wget -O /tmp/luci-app-oasis_3.0.0-r1_all.ipk https://github.com/utakamo/oasis/releases/download/v3.0.0/luci-app-oasis_3.0.0-r1_all.ipk
wget -O /tmp/oasis-mod-tool_1.0.0-r1_all.ipk https://github.com/utakamo/oasis/releases/download/v3.0.0/oasis-mod-tool_1.0.0-r1_all.ipk

# Install packages from /tmp
opkg install /tmp/oasis_3.0.0-r1_all.ipk
opkg install /tmp/luci-app-oasis_3.0.0-r1_all.ipk
opkg install /tmp/oasis-mod-tool_1.0.0-r1_all.ipk

# Verify installation
echo "Installed packages:"
opkg list-installed | grep -E 'oasis|luci-app-oasis|oasis-mod-tool'

# Clean up temporary files if no longer needed
rm -f /tmp/oasis_3.0.0-r1_all.ipk \
      /tmp/luci-app-oasis_3.0.0-r1_all.ipk \
      /tmp/oasis-mod-tool_1.0.0-r1_all.ipk

# Completion message
echo "Oasis installation completed successfully!"

# Ask for reboot
echo -n "Do you want to reboot now? [Y/n]: "
read answer
if [ "$answer" = "Y" ] || [ "$answer" = "y" ]; then
    echo "Rebooting system..."
    reboot
else
    echo "Reboot skipped. Please reboot manually later to apply changes."
fi
