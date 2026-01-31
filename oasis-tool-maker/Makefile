include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-tool-maker
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

RPCD_APP_DIR = /usr/libexec/rpcd
LUCI_CONTROLLER_DIR = /usr/lib/lua/luci/controller
LUCI_VIEW_DIR = /usr/lib/lua/luci/view
LUCI_RESOURCE_DIR = /www/luci-static/resources
LUA_LIBRARY_DIR = /usr/lib/lua
ETC_TOOL_MAKER_DIR = /etc/oasis/tool-maker

include $(INCLUDE_DIR)/package.mk

define Package/oasis-tool-maker
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= Oasis Local Tool Maker
    DEPENDS:=+oasis-mod-tool
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis-tool-maker/install
	$(INSTALL_DIR) $(1)$(RPCD_APP_DIR)
	$(INSTALL_DIR) $(1)$(LUCI_CONTROLLER_DIR)/oasis-tool-maker
	$(INSTALL_DIR) $(1)$(LUCI_VIEW_DIR)/oasis
	$(INSTALL_DIR) $(1)$(LUCI_RESOURCE_DIR)/oasis/js
	$(INSTALL_DIR) $(1)$(LUCI_RESOURCE_DIR)/oasis/css
	$(INSTALL_DIR) $(1)$(ETC_TOOL_MAKER_DIR)/lua
	$(INSTALL_DIR) $(1)$(ETC_TOOL_MAKER_DIR)/ucode
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/tool/maker
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.tool.maker $(1)$(RPCD_APP_DIR)
	$(INSTALL_DATA) ./files/luci/controller/module.lua $(1)$(LUCI_CONTROLLER_DIR)/oasis-tool-maker/module.lua
	$(INSTALL_DATA) ./files/luci/view/tool-maker.htm $(1)$(LUCI_VIEW_DIR)/oasis/tool-maker.htm
	$(INSTALL_DATA) ./files/luci/www/luci-static/resources/oasis/js/tool-maker.js $(1)$(LUCI_RESOURCE_DIR)/oasis/js
	$(INSTALL_DATA) ./files/luci/www/luci-static/resources/oasis/css/tool-maker.css $(1)$(LUCI_RESOURCE_DIR)/oasis/css
	$(INSTALL_DATA) ./files/etc/oasis/tool-maker/lua/template $(1)$(ETC_TOOL_MAKER_DIR)/lua/template
	$(INSTALL_DATA) ./files/etc/oasis/tool-maker/ucode/template $(1)$(ETC_TOOL_MAKER_DIR)/ucode/template
	$(INSTALL_DATA) ./files/usr/lib/lua/oasis/tool/maker/template.lua $(1)$(LUA_LIBRARY_DIR)/oasis/tool/maker/template.lua
endef

$(eval $(call BuildPackage,oasis-tool-maker))
