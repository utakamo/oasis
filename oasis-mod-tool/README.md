# Oasis Local Tool (OLT) Server System
> [!IMPORTANT]
> >
> As of July 2025, the oasis-mod-tool cannot run properly. Therefore, you'll need to wait for its official release before using it.

Oasis provides the oasis-mod-tool as a plugin module, enabling AI systems to leverage OpenWrt functionality.
The oasis-mod-tool utilizes Lua and uCode scripts that can run as ubus server applications, enabled by OpenWrt’s ubus and rpcd modules.
After installing oasis-mod-tool, you can create Lua or uCode scripts using the syntax rules shown in the examples below. By placing the scripts in the appropriate directory, AI will detect the functionalities defined within them and recognize them as tools.  

## Lua Script Sample
```

```

## uCode Script Sample
```

```

## How to Apply the Script
To have Oasis recognize the scripts you've created, you’ll need to either reboot OpenWrt or run the command shown below.
```
root@OpenWrt~# /etc/init.d/olt_tool restart
root@OpenWrt~# service rpcd restart
```
> [!NOTE]
> If your script includes multiple module imports or similar operations, it may take a few minutes (typically 1 to 3) before it’s recognized by the Oasis/OpenWrt system.
