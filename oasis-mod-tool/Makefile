include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-mod-tool
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

INIT_DIR = /etc/init.d
LIBRARY_DIR = /usr/lib/lua
UBUS_SERVER_APP_DIR = /usr/libexec/rpcd

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
	$(INSTALL_DIR) $(1)$(INIT_DIR)
	$(INSTALL_DIR) $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_DIR) $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service
	$(INSTALL_DIR) $(1)$(LIBRARY_DIR)/oasis/local/tool
	$(INSTALL_BIN) ./files/etc/init.d/olt_tool.init $(1)$(INIT_DIR)/olt_tool
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.util.tool.server $(1)$(UBUS_SERVER_APP_DIR)/oasis.util.tool.server
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/function_calling.lua $(1)$(LIBRARY_DIR)/oasis/local/function_calling.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/tool/client.lua $(1)$(LIBRARY_DIR)/oasis/local/tool/client.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/tool/server.lua $(1)$(LIBRARY_DIR)/oasis/local/tool/server.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/anthropic.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/anthropic.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/google.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/google.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/ollama.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/ollama.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/openai.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/openai.lua
endef

define Package/oasis-mod-tool/postinst
	#!/bin/sh
	uci set oasis.support.local_tools=1
	uci set oasis.support.remote_mcp_server=1
	uci commit oasis
	#TODO: Check below
	#mkdir -p /tmp/oasis
	#touch /tmp/oasis/reboot_required
endef

$(eval $(call BuildPackage,oasis-mod-tool))
