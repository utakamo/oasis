include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-tool-edge
PKG_VERSION:=1.0.0
PKG_RELEASE:=2

LUA_UBUS_SERVER_APP_DIR = /usr/libexec/rpcd
RPCD_ACL_DIR = /usr/share/rpcd/acl.d
UCI_DEFAULTS_DIR = /etc/uci-defaults

include $(INCLUDE_DIR)/package.mk

define Package/oasis-tool-edge
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= Module for executing AI tools through RPC calls
    DEPENDS:=+oasis-mod-tool
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis-tool-edge/install
	$(INSTALL_DIR) $(1)$(LUA_UBUS_SERVER_APP_DIR)
	$(INSTALL_DIR) $(1)$(RPCD_ACL_DIR)
	$(INSTALL_DIR) $(1)$(UCI_DEFAULTS_DIR)
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.tool.edge $(1)$(LUA_UBUS_SERVER_APP_DIR)
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/oasis-tool-edge.json $(1)$(RPCD_ACL_DIR)
	$(INSTALL_BIN) ./files/etc/uci-defaults/81_oasis-tool-edge $(1)$(UCI_DEFAULTS_DIR)
endef

define Package/oasis-tool-edge/postinst
	#!/bin/sh
	[ -n "$${IPKG_INSTROOT}" ] && exit 0
	if [ -f /etc/config/oasis ]; then
		uci -q set oasis.support.tool_edge='1'
		uci -q commit oasis
	fi
	exit 0
endef

define Package/oasis-tool-edge/postrm
	#!/bin/sh
	[ -n "$${IPKG_INSTROOT}" ] && exit 0
	# postrm also runs while a package is being replaced.  Do not delete the
	# managed rpcd login here or an ordinary Oasis upgrade would erase it.
	if [ -f /etc/config/oasis ]; then
		uci -q set oasis.support.tool_edge='0'
		uci -q commit oasis
	fi
	exit 0
endef

$(eval $(call BuildPackage,oasis-tool-edge))
