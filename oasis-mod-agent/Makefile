include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-mod-agent
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

APP_DIR := /usr/lib/lua/oasis/agent

include $(INCLUDE_DIR)/package.mk

define Package/oasis-mod-agent
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= Agent mode plugin for Oasis
    DEPENDS:=+oasis-mod-tool
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis-mod-agent/install
	$(INSTALL_DIR) $(1)$(APP_DIR)
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/agent/main.lua $(1)$(APP_DIR)/main.lua
endef

$(eval $(call BuildPackage,oasis-mod-agent))
