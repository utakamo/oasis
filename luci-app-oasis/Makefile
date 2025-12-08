include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-oasis
PKG_VERSION:=3.2.6
PKG_RELEASE:=1

SOURCE_DIR:=./files/luci

LUA_LIBRARYDIR = /usr/lib/lua
LUCI_LIBRARYDIR = $(LUA_LIBRARYDIR)/luci
LUCI_VIEWDIR = $(LUCI_LIBRARYDIR)/view
LUCI_RESOURCES_DIR = /www/luci-static/resources

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-oasis
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= AI Support Application
    DEPENDS:=+oasis +luci-compat
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/luci-app-oasis/install
	$(INSTALL_DIR) $(1)$(LUCI_VIEWDIR)/oasis
	$(INSTALL_DIR) $(1)$(LUCI_RESOURCES_DIR)/oasis
	$(INSTALL_DIR) $(1)$(LUCI_RESOURCES_DIR)/oasis/css
	$(INSTALL_DIR) $(1)$(LUCI_RESOURCES_DIR)/oasis/js
	$(INSTALL_DATA) $(SOURCE_DIR)/view/icons.htm $(1)$(LUCI_VIEWDIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/view/sysmsg.htm $(1)$(LUCI_VIEWDIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/view/chat.htm $(1)$(LUCI_VIEWDIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/view/rollback-list.htm $(1)$(LUCI_VIEWDIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/view/tools.htm $(1)$(LUCI_VIEWDIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/css/chat.css $(1)$(LUCI_RESOURCES_DIR)/oasis/css
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/css/icons.css $(1)$(LUCI_RESOURCES_DIR)/oasis/css
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/css/rollback-list.css $(1)$(LUCI_RESOURCES_DIR)/oasis/css
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/css/sysmsg.css $(1)$(LUCI_RESOURCES_DIR)/oasis/css
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/css/tools.css $(1)$(LUCI_RESOURCES_DIR)/oasis/css
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/js/chat.js $(1)$(LUCI_RESOURCES_DIR)/oasis/js
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/js/chat-utils.js $(1)$(LUCI_RESOURCES_DIR)/oasis/js
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/js/icons.js $(1)$(LUCI_RESOURCES_DIR)/oasis/js
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/js/rollback.js $(1)$(LUCI_RESOURCES_DIR)/oasis/js
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/js/sysmsg.js $(1)$(LUCI_RESOURCES_DIR)/oasis/js
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/js/tools.js $(1)$(LUCI_RESOURCES_DIR)/oasis/js
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/operator.png $(1)$(LUCI_RESOURCES_DIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/openwrt.png $(1)$(LUCI_RESOURCES_DIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/fonts/flUhRq6tzZclQEJ-Vdg-IuiaDsNc.woff2 $(1)$(LUCI_RESOURCES_DIR)/oasis/fonts
endef

define Package/luci-app-oasis/postinst
	#!/bin/sh
	uci set oasis.support.webui=1
	if [ $? -eq 0 ]; then
		uci commit oasis
	fi
endef

$(eval $(call BuildPackage,luci-app-oasis))
