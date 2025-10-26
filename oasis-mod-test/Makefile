include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-mod-test
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LUA_LIBRARY_DIR = /usr/lib/lua

include $(INCLUDE_DIR)/package.mk

define Package/oasis-mod-test
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= test module for oasis
    DEPENDS:=+oasis
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis-mod-test/install
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/test
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/test/main.lua $(1)$(LUA_LIBRARY_DIR)/oasis/test
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/oasis_test_runner.lua $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/etc/oasis
	$(INSTALL_CONF) ./files/etc/oasis/oasis-test.conf $(1)/etc/oasis/oasis-test.conf
endef

$(eval $(call BuildPackage,oasis-mod-test))
