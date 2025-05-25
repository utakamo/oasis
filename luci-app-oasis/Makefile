include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-oasis
PKG_VERSION:=1.5.3
PKG_RELEASE:=1

SOURCE_DIR:=./files/luci

LUA_LIBRARYDIR = /usr/lib/lua
LUCI_LIBRARYDIR = $(LUA_LIBRARYDIR)/luci
LUCI_MODULEDIR = $(LUCI_LIBRARYDIR)/controller
LUCI_MODELDIR = $(LUCI_LIBRARYDIR)/model/cbi
LUCI_VIEWDIR = $(LUCI_LIBRARYDIR)/view

LUCI_CGI_BIN_DIR = /www/cgi-bin
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
	$(INSTALL_DIR) $(1)$(LUCI_MODULEDIR)/luci-app-oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/controller/module.lua $(1)$(LUCI_MODULEDIR)/luci-app-oasis
	$(INSTALL_DIR) $(1)$(LUCI_MODELDIR)/luci-app-oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/model/cbi/setting.lua $(1)$(LUCI_MODELDIR)/luci-app-oasis
	$(INSTALL_DIR) $(1)$(LUCI_VIEWDIR)/luci-app-oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/view/icons.htm $(1)$(LUCI_VIEWDIR)/luci-app-oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/view/sysmsg.htm $(1)$(LUCI_VIEWDIR)/luci-app-oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/view/chat.htm $(1)$(LUCI_VIEWDIR)/luci-app-oasis
	$(INSTALL_DATA) $(SOURCE_DIR)/view/rollback-list.htm $(1)$(LUCI_VIEWDIR)/luci-app-oasis
	$(INSTALL_DIR) $(1)$(LUCI_RESOURCES_DIR)/luci-app-oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/luci-app-oasis/chat.css $(1)$(LUCI_RESOURCES_DIR)/luci-app-oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/luci-app-oasis/operator.png $(1)$(LUCI_RESOURCES_DIR)/luci-app-oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/luci-app-oasis/openwrt.png $(1)$(LUCI_RESOURCES_DIR)/luci-app-oasis
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/luci-app-oasis/chat.css $(1)$(LUCI_RESOURCES_DIR)/luci-app-oasis
	$(INSTALL_DIR) $(1)$(LUCI_RESOURCES_DIR)/luci-app-oasis/fonts
	$(INSTALL_DATA) $(SOURCE_DIR)$(LUCI_RESOURCES_DIR)/luci-app-oasis/fonts/flUhRq6tzZclQEJ-Vdg-IuiaDsNc.woff2 $(1)$(LUCI_RESOURCES_DIR)/luci-app-oasis/fonts
	$(INSTALL_DIR) $(1)$(LUCI_CGI_BIN_DIR)
	$(INSTALL_BIN) $(SOURCE_DIR)$(LUCI_CGI_BIN_DIR)/oasis $(1)$(LUCI_CGI_BIN_DIR)
endef

$(eval $(call BuildPackage,luci-app-oasis))
