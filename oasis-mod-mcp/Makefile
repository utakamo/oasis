include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-mod-mcp
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LIBRARY_DIR = /usr/lib/lua
OASIS_MERGE_CONFIG_DIR = /etc/oasis/tool
UBUS_SERVER_APP_DIR = /usr/libexec/rpcd

include $(INCLUDE_DIR)/package.mk

define Package/oasis-mod-mcp
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= Remote MCP and Local Tool Plugin Module for oasis
    DEPENDS:=+oasis
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis-mod-mcp/install
	$(INSTALL_DIR) $(1)$(OASIS_MERGE_CONFIG_DIR)
	$(INSTALL_DIR) $(1)$(UBUS_SERVER_APP_DIR)
	$(INSTALL_DIR) $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service
	$(INSTALL_DIR) $(1)$(LIBRARY_DIR)/oasis/local
	$(INSTALL_DATA) ./files/etc/oasis/tool/tool.config $(1)$(OASIS_MERGE_CONFIG_DIR)
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.util.mcp.server $(1)$(UBUS_SERVER_APP_DIR)/oasis.util.mcp.server
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/function_calling.lua $(1)$(LIBRARY_DIR)/oasis/local/function_calling.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/mcp_client.lua $(1)$(LIBRARY_DIR)/oasis/local/mcp_client.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/mcp_server.lua $(1)$(LIBRARY_DIR)/oasis/local/mcp_server.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/anthropic.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/anthropic.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/google.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/google.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/ollama.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/ollama.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/openai.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/openai.lua
endef

define Package/oasis-mod-mcp/postinst
	#!/bin/sh
	uci set oasis.support.local_tools=1
	uci set oasis.support.remote_mcp_server=1
	uci -f /etc/oasis/tool/tool.config -m import oasis
	uci commit oasis
	#TODO: Check below
	#mkdir -p /tmp/oasis
	#touch /tmp/oasis/reboot_required
endef

$(eval $(call BuildPackage,oasis-mod-mcp))
