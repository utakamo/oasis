include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-mcp
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LIBRARY_DIR = /usr/lib/lua
UBUS_SERVER_APP_DIR = /usr/libexec/rpcd
UCI_CONFIG_DIR = /etc/config

include $(INCLUDE_DIR)/package.mk

define Package/oasis-mcp
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= MCP Plugin Module for oasis
    DEPENDS:=+oasis +uhttp-mod-ubus
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis-mcp/install
	$(INSTALL_DIR) $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_DIR) $(1)$(LIBRARY_DIR)/oasis/chat/mcp
	$(INSTALL_DIR) $(1)$(UCI_CONFIG_DIR)
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.mcp.server $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_DATA) ./files/usr/lib/lua/oasis/chat/mcp/client.lua $(1)$(LIBRARY_DIR)/oasis/chat/mcp
	$(INSTALL_DATA) ./files/etc/config/oasis-mcp.config $(1)$(UCI_CONFIG_DIR)/oasis-mcp
endef

$(eval $(call BuildPackage,oasis-mcp))
