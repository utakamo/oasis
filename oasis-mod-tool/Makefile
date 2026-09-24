include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-mod-tool
PKG_VERSION:=1.1.1
PKG_RELEASE:=11

USR_BIN_DIR = /usr/bin
RPCD_ACL_DIR = /usr/share/rpcd/acl.d
INIT_DIR = /etc/init.d
LUA_LIBRARY_DIR = /usr/lib/lua
UCODE_LIBRARY_DIR = /usr/share/ucode
LUA_UBUS_SERVER_APP_DIR = /usr/libexec/rpcd
UCODE_UBUS_SERVER_APP_DIR = /usr/share/rpcd/ucode
LUCI_MODULEDIR = /usr/lib/lua/luci/controller
OASIS_MANIFEST_DIR = /etc/oasis/tool-manifest.d

include $(INCLUDE_DIR)/package.mk

define Package/oasis-mod-tool
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= Remote MCP and Local Tool Plugin Module for oasis
    DEPENDS:=+oasis
    EXTRA_DEPENDS:=oasis (>=3.2.6-r17)
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis-mod-tool/install
	$(INSTALL_DIR) $(1)$(USR_BIN_DIR)
	$(INSTALL_DIR) $(1)$(INIT_DIR)
	$(INSTALL_DIR) $(1)$(RPCD_ACL_DIR)
	$(INSTALL_DIR) $(1)$(LUA_UBUS_SERVER_APP_DIR)
	$(INSTALL_DIR) $(1)$(UCODE_UBUS_SERVER_APP_DIR)
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/remote/mcp/service
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/package
	$(INSTALL_DIR) $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/system
	$(INSTALL_DIR) $(1)$(UCODE_LIBRARY_DIR)/oasis/local/tool
	$(INSTALL_DIR) $(1)$(LUCI_MODULEDIR)/oasis-tool
	$(INSTALL_DIR) $(1)$(OASIS_MANIFEST_DIR)
	$(INSTALL_BIN) ./files/usr/bin/oasis_tool_setup $(1)$(USR_BIN_DIR)
	$(INSTALL_BIN) ./files/etc/init.d/olt_tool.init $(1)$(INIT_DIR)/olt_tool
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/oasis-mod-tool.json $(1)$(RPCD_ACL_DIR)
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.network $(1)$(LUA_UBUS_SERVER_APP_DIR)/oasis.network
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.wireless $(1)$(LUA_UBUS_SERVER_APP_DIR)/oasis.wireless
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.system $(1)$(LUA_UBUS_SERVER_APP_DIR)/oasis.system
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.service $(1)$(LUA_UBUS_SERVER_APP_DIR)/oasis.service
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.tool.manager $(1)$(LUA_UBUS_SERVER_APP_DIR)/oasis.tool.manager
	$(INSTALL_DATA) ./files/usr/share/rpcd/ucode/oasis_plugin_server.uc $(1)$(UCODE_UBUS_SERVER_APP_DIR)/oasis_plugin_server.uc
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/tool/client.lua $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/client.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/tool/server.lua $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/server.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/oasis/local/tool/state.lua $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/state.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/oasis/local/tool/auto_store.lua $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/auto_store.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/oasis/local/tool/uci_transaction.lua $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/uci_transaction.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/tool/package/manager.lua $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/package/manager.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/local/tool/system/command.lua $(1)$(LUA_LIBRARY_DIR)/oasis/local/tool/system/command.lua
	$(INSTALL_DATA) ./files/usr/share/ucode/oasis/local/tool/server.uc $(1)$(UCODE_LIBRARY_DIR)/oasis/local/tool/server.uc
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/anthropic.lua $(1)$(LUA_LIBRARY_DIR)/oasis/remote/mcp/service/anthropic.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/google.lua $(1)$(LUA_LIBRARY_DIR)/oasis/remote/mcp/service/google.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/ollama.lua $(1)$(LUA_LIBRARY_DIR)/oasis/remote/mcp/service/ollama.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/openai.lua $(1)$(LUA_LIBRARY_DIR)/oasis/remote/mcp/service/openai.lua
	$(INSTALL_DATA) ./files/luci/controller/module.lua  $(1)$(LUCI_MODULEDIR)/oasis-tool/module.lua
	$(INSTALL_DATA) ./files/etc/oasis/tool-manifest.d/*.json $(1)$(OASIS_MANIFEST_DIR)/
endef

define Package/oasis-mod-tool/postinst
	#!/bin/sh
	[ -n "$${IPKG_INSTROOT}" ] && exit 0
	fail_setup() { \
		logger -t oasis-mod-tool "$$1"; \
		echo "oasis-mod-tool: $$1" >&2; \
		exit 1; \
	}; \
	[ -x /usr/bin/oasis ] || fail_setup "oasis command is unavailable"; \
	[ -x /usr/bin/oasis_tool_setup ] || \
		fail_setup "oasis_tool_setup command is unavailable"; \
	if ! /usr/bin/oasis_tool_setup initialize-package \
		>/dev/null 2>&1; then \
		fail_setup "failed to initialize package-owned tool state"; \
	fi
	mkdir -p /tmp/oasis
	touch /tmp/oasis/reboot_required_for_oasis-mod-tool
endef

define Package/oasis-mod-tool/prerm
	#!/bin/sh
	[ -n "$${IPKG_INSTROOT}" ] && exit 0
	[ "$${PKG_UPGRADE}" = "1" ] && exit 0
	if [ -x /usr/bin/oasis_tool_setup ]; then
		if ! /usr/bin/oasis_tool_setup delete --remove-marker \
			>/dev/null 2>&1; then \
			logger -t oasis-mod-tool "failed to remove package tool state"; \
			echo "oasis-mod-tool: failed to remove package tool state" >&2; \
			exit 1; \
		fi; \
	fi
endef

$(eval $(call BuildPackage,oasis-mod-tool))
