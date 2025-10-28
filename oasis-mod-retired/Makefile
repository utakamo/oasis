include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-mod-retired
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

APP_DIR = /usr/bin
LUA_LIBRARY_DIR = /usr/lib/lua

include $(INCLUDE_DIR)/package.mk

define Package/oasis-mod-retired
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= Archive module for deprecated features
    DEPENDS:=+oasis
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis-mod-retired/install
    $(INSTALL_DIR) $(1)$(APP_DIR)
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/chat
	$(INSTALL_BIN) ./files/usr/bin/oasisd $(1)$(APP_DIR)
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/filter.lua $(1)$(LUA_LIBRARY_DIR)/oasis/chat
endef

$(eval $(call BuildPackage,oasis-mod-retired))
