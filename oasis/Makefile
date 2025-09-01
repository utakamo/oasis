include $(TOPDIR)/rules.mk

PKG_NAME:=oasis
PKG_VERSION:=3.0.0
PKG_RELEASE:=1

APP_DIR = /usr/bin
UBUS_SERVER_APP_DIR = /usr/libexec/rpcd
UCI_CONFIG_DIR = /etc/config
OASIS_DIR = /etc/oasis
INIT_DIR = /etc/init.d
RPCD_ACL_DIR = /usr/share/rpcd/acl.d
STORAGE_DIR = $(OASIS_DIR)/chat_data
BACKUP_DIR = $(OASIS_DIR)/backup
LUCI_MAIN_DIR:=./files/luci
LUA_LIBRARY_DIR = /usr/lib/lua
LUCI_LIBRARYDIR = $(LUA_LIBRARY_DIR)/luci
LUCI_MODULEDIR = $(LUCI_LIBRARYDIR)/controller
LUCI_MODELDIR = $(LUCI_LIBRARYDIR)/model/cbi
LUCI_CGI_BIN_DIR = /www/cgi-bin

include $(INCLUDE_DIR)/package.mk

define Package/oasis
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= AI Support Application
    DEPENDS:=+lua-curl-v3 +luci-compat
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis/install
	$(INSTALL_DIR) $(1)$(INIT_DIR)
	$(INSTALL_DIR) $(1)$(RPCD_ACL_DIR)
	$(INSTALL_DIR) $(1)$(APP_DIR)
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/chat
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/ubus
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/chat/service
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/unified/chat
	$(INSTALL_DIR) $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_DIR) $(1)$(UCI_CONFIG_DIR)
	$(INSTALL_DIR) $(1)$(STORAGE_DIR)
	$(INSTALL_DIR) $(1)$(BACKUP_DIR)
	$(INSTALL_DIR) $(1)$(BACKUP_DIR)/list1
	$(INSTALL_DIR) $(1)$(BACKUP_DIR)/list2
	$(INSTALL_DIR) $(1)$(BACKUP_DIR)/list3
	$(INSTALL_DIR) $(1)$(BACKUP_DIR)/list4
	$(INSTALL_DIR) $(1)$(BACKUP_DIR)/list5
	$(INSTALL_DIR) $(1)$(BACKUP_DIR)/list6
	$(INSTALL_DIR) $(1)$(BACKUP_DIR)/list7
	$(INSTALL_DIR) $(1)$(BACKUP_DIR)/list8
	$(INSTALL_DIR) $(1)$(BACKUP_DIR)/list9
	$(INSTALL_DIR) $(1)$(BACKUP_DIR)/list10
	$(INSTALL_DIR) $(1)$(LUCI_MODULEDIR)/oasis
	$(INSTALL_DIR) $(1)$(LUCI_MODELDIR)/oasis
	$(INSTALL_DIR) $(1)$(LUCI_CGI_BIN_DIR)
	$(INSTALL_BIN) ./files/etc/init.d/oasis.init $(1)$(INIT_DIR)/oasis
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/oasis.json $(1)$(RPCD_ACL_DIR)
	$(INSTALL_BIN) ./files/usr/bin/oasis $(1)$(APP_DIR)
	$(INSTALL_BIN) ./files/usr/bin/oasisd $(1)$(APP_DIR)
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/datactrl.lua $(1)$(LUA_LIBRARY_DIR)/oasis/chat
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/main.lua $(1)$(LUA_LIBRARY_DIR)/oasis/chat
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/transfer.lua $(1)$(LUA_LIBRARY_DIR)/oasis/chat
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/filter.lua $(1)$(LUA_LIBRARY_DIR)/oasis/chat
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/apply.lua $(1)$(LUA_LIBRARY_DIR)/oasis/chat
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/misc.lua $(1)$(LUA_LIBRARY_DIR)/oasis/chat
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/debug.lua $(1)$(LUA_LIBRARY_DIR)/oasis/chat
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/unified/chat/schema.lua $(1)$(LUA_LIBRARY_DIR)/oasis/unified/chat
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/service/ollama.lua $(1)$(LUA_LIBRARY_DIR)/oasis/chat/service
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/service/openai.lua $(1)$(LUA_LIBRARY_DIR)/oasis/chat/service
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/service/anthropic.lua $(1)$(LUA_LIBRARY_DIR)/oasis/chat/service
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/chat/service/gemini.lua $(1)$(LUA_LIBRARY_DIR)/oasis/chat/service
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/common.lua $(1)$(LUA_LIBRARY_DIR)/oasis
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/ubus/util.lua $(1)$(LUA_LIBRARY_DIR)/oasis/ubus
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.chat $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.title $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_DATA) ./files/etc/config/oasis.config $(1)$(UCI_CONFIG_DIR)/oasis
	$(INSTALL_DATA) ./files/etc/oasis/oasis.conf $(1)$(OASIS_DIR)
	$(INSTALL_DATA) $(LUCI_MAIN_DIR)/controller/module.lua $(1)$(LUCI_MODULEDIR)/oasis
	$(INSTALL_DATA) $(LUCI_MAIN_DIR)/model/cbi/setting.lua $(1)$(LUCI_MODELDIR)/oasis
	$(INSTALL_BIN) $(LUCI_MAIN_DIR)$(LUCI_CGI_BIN_DIR)/oasis $(1)$(LUCI_CGI_BIN_DIR)
endef

define Package/oasis/postinst
	#!/bin/sh
	mkdir -p /tmp/oasis
	touch /tmp/oasis/reboot_required_for_oasis
endef

$(eval $(call BuildPackage,oasis))
