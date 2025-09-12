include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-mod-tool
PKG_VERSION:=1.0.4
PKG_RELEASE:=1

USR_BIN_DIR = /usr/bin
INIT_DIR = /etc/init.d
LUA_LIBRARY_DIR = /usr/lib/lua
UCODE_LIBRARY_DIR = /usr/share/ucode
LUA_UBUS_SERVER_APP_DIR = /usr/libexec/rpcd
UCODE_UBUS_SERVER_APP_DIR = /usr/share/rpcd/ucode
include $(INCLUDE_DIR)/package.mk

define Package/oasis-mod-tool
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= Remote MCP and Local Tool Plugin Module for oasis
    DEPENDS:=+oasis
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis-mod-tool/install
	$(INSTALL_DIR) $(1)$(USR_BIN_DIR)
	$(INSTALL_DIR) $(1)$(INIT_DIR)
	$(INSTALL_DIR) $(1)$(LUA_UBUS_SERVER_APP_DIR)
	$(INSTALL_DIR) $(1)$(UCODE_UBUS_SERVER_APP_DIR)
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/remote/mcp/service
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/package
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/system
	$(INSTALL_DIR) $(1)$(UCODE_LIBRARY_DIR)/oasis/local/tool
	$(INSTALL_BIN) ./files/usr/bin/oasis_tool_setup $(1)$(USR_BIN_DIR)
	$(INSTALL_BIN) ./files/etc/init.d/olt_tool.init $(1)$(INIT_DIR)/olt_tool
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.lua.tool.server $(1)$(LUA_UBUS_SERVER_APP_DIR)/oasis.lua.tool.server
	$(INSTALL_DATA) ./files/usr/share/rpcd/ucode/oasis_plugin_server.uc $(1)$(UCODE_UBUS_SERVER_APP_DIR)/oasis_plugin_server.uc
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/tool/client.lua $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/client.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/tool/server.lua $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/server.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/tool/package/manager.lua $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/package/manager.lua
		$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/tool/system/command.lua $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/system/command.lua
	$(INSTALL_DATA) ./files/usr/share/ucode/oasis/local/tool/server.uc $(1)$(UCODE_LIBRARY_DIR)/oasis/local/tool/server.uc
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/anthropic.lua $(1)$(LUA_LIBRARY_DIR)/oasis/remote/mcp/service/anthropic.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/google.lua $(1)$(LUA_LIBRARY_DIR)/oasis/remote/mcp/service/google.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/ollama.lua $(1)$(LUA_LIBRARY_DIR)/oasis/remote/mcp/service/ollama.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/openai.lua $(1)$(LUA_LIBRARY_DIR)/oasis/remote/mcp/service/openai.lua
endef

define Package/oasis-mod-tool/postinst
	#!/bin/sh
	uci set oasis.support.local_tool=1
	uci set oasis.support.remote_mcp_server=1
	uci commit oasis
	mkdir -p /tmp/oasis
	touch /tmp/oasis/reboot_required_for_oasis-mod-tool
endef

$(eval $(call BuildPackage,oasis-mod-tool))
