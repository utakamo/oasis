include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-aihelper
PKG_VERSION:=1.0
PKG_RELEASE:=1

SOURCE_DIR:=./files/luci

LUA_LIBRARYDIR = /usr/lib/lua
LUCI_LIBRARYDIR = $(LUA_LIBRARYDIR)/luci
LUCI_MODULEDIR = $(LUCI_LIBRARYDIR)/controller
LUCI_MODELDIR = $(LUCI_LIBRARYDIR)/model/cbi
LUCI_VIEWDIR = $(LUCI_LIBRARYDIR)/view

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-aihelper
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= AI Support Application
    DEPENDS:=+aihelper
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/luci-app-aihelper/install
	$(INSTALL_DIR) $(1)$(LUCI_MODULEDIR)/luci-app-aihelper
	$(INSTALL_DATA) $(SOURCE_DIR)/controller/module.lua $(1)$(LUCI_MODULEDIR)/luci-app-aihelper
	$(INSTALL_DIR) $(1)$(LUCI_MODELDIR)/luci-app-aihelper
	$(INSTALL_DATA) $(SOURCE_DIR)/model/cbi/setting.lua $(1)$(LUCI_MODELDIR)/luci-app-aihelper
	$(INSTALL_DIR) $(1)$(LUCI_VIEWDIR)/luci-app-aihelper
	$(INSTALL_DATA) $(SOURCE_DIR)/view/chat.htm $(1)$(LUCI_VIEWDIR)/luci-app-aihelper
endef

$(eval $(call BuildPackage,luci-app-aihelper))
