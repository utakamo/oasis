include $(TOPDIR)/rules.mk

PKG_NAME:=oasis
PKG_VERSION:=1.0
PKG_RELEASE:=1

APP_DIR = /usr/bin
LIBRARY_DIR = /usr/lib/lua
UBUS_SERVER_APP_DIR = /usr/libexec/rpcd
UCI_CONFIG_DIR = /etc/config
OASIS_DIR = /etc/oasis
STORAGE_DIR = $(OASIS_DIR)/chat_data

include $(INCLUDE_DIR)/package.mk

define Package/oasis
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= AI Support Application
    DEPENDS:=+lua-curl-v3
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis/install
	$(INSTALL_DIR) $(1)$(APP_DIR)
	$(INSTALL_DIR) $(1)$(LIBRARY_DIR)/oasis/chat
	$(INSTALL_DIR) $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_DIR) $(1)$(UCI_CONFIG_DIR)
	$(INSTALL_DIR) $(1)$(STORAGE_DIR)
	$(INSTALL_BIN) ./files/usr/bin/oasis $(1)$(APP_DIR)
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/ctrl.lua $(1)$(LIBRARY_DIR)/oasis/chat
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/transfer.lua $(1)$(LIBRARY_DIR)/oasis/chat
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/common.lua $(1)$(LIBRARY_DIR)/oasis
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.chat $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.title $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_DATA) ./files/etc/config/oasis.config $(1)$(UCI_CONFIG_DIR)/oasis
	$(INSTALL_DATA) ./files/etc/oasis/oasis.conf $(1)$(OASIS_DIR)
endef

$(eval $(call BuildPackage,oasis))
