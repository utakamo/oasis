include $(TOPDIR)/rules.mk

PKG_NAME:=aihelper
PKG_VERSION:=1.0
PKG_RELEASE:=1

APP_DIR = /usr/bin
LIBRARY_DIR = /usr/lib/lua
UBUS_SERVER_APP_DIR = /usr/libexec/rpcd
UCI_CONFIG_DIR = /etc/config
STORAGE_DIR = /etc/aihelper/chat_data

include $(INCLUDE_DIR)/package.mk

define Package/aihelper
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= AI Support Application
    DEPENDS:=+lua-curl-v3
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/aihelper/install
	$(INSTALL_DIR) $(1)$(APP_DIR)
	$(INSTALL_DIR) $(1)$(LIBRARY_DIR)
	$(INSTALL_DIR) $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_DIR) $(1)$(UCI_CONFIG_DIR)
	$(INSTALL_DIR) $(1)$(STORAGE_DIR)
	$(INSTALL_BIN) ./files/usr/bin/aihelper $(1)$(APP_DIR)
	$(INSTALL_BIN) ./files/usr/lib/lua/ai_chat_ctrl.lua $(1)$(LIBRARY_DIR)
	$(INSTALL_BIN) ./files/usr/lib/lua/ai_chat_transfer.lua $(1)$(LIBRARY_DIR)
	$(INSTALL_BIN) ./files/usr/lib/lua/aihelper_common.lua $(1)$(LIBRARY_DIR)
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/aihelper $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/aihelper.chat $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/aihelper.title $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_DATA) ./files/etc/config/aihelper.config $(1)$(UCI_CONFIG_DIR)/aihelper
endef

$(eval $(call BuildPackage,aihelper))
