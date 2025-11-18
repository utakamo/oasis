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
	$(INSTALL_DATA) $(SOURCE_DIR)/view/icons.htm $(1)$(LUCI_VIEWDIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/view/sysmsg.htm $(1)$(LUCI_VIEWDIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/view/chat.htm $(1)$(LUCI_VIEWDIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/view/rollback-list.htm $(1)$(LUCI_VIEWDIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/view/tools.htm $(1)$(LUCI_VIEWDIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/chat.css $(1)$(LUCI_RESOURCES_DIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/icons.css $(1)$(LUCI_RESOURCES_DIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/rollback-list.css $(1)$(LUCI_RESOURCES_DIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/sysmsg.css $(1)$(LUCI_RESOURCES_DIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/tools.css $(1)$(LUCI_RESOURCES_DIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/operator.png $(1)$(LUCI_RESOURCES_DIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/openwrt.png $(1)$(LUCI_RESOURCES_DIR)/oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/oasis/fonts/flUhRq6tzZclQEJ-Vdg-IuiaDsNc.woff2 $(1)$(LUCI_RESOURCES_DIR)/oasis
endef

define Package/luci-app-oasis/postinst
	#!/bin/sh
	uci set oasis.support.webui=1
	uci commit oasis
endef


$(eval $(call BuildPackage,luci-app-oasis))
