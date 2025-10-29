include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-tool-edge
PKG_VERSION:=1.1.1
PKG_RELEASE:=1

LUA_UBUS_SERVER_APP_DIR = /usr/libexec/rpcd

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
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.tool.edge $(1)$(LUA_UBUS_SERVER_APP_DIR)
endef

$(eval $(call BuildPackage,oasis-tool-edge))
