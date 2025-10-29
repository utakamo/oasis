include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-tool-edge
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUA_UBUS_SERVER_APP_DIR = /usr/libexec/rpcd
RPCD_ACL_DIR = /usr/share/rpcd/acl.d

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
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.tool.edge $(1)$(LUA_UBUS_SERVER_APP_DIR)
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/oasis-tool-edge.json $(1)$(RPCD_ACL_DIR)
endef

$(eval $(call BuildPackage,oasis-tool-edge))
