include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-mod-tools
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LIBRARY_DIR = /usr/lib/lua
OASIS_MERGE_CONFIG_DIR = /etc/oasis/tool

include $(INCLUDE_DIR)/package.mk

define Package/oasis-mod-tools
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= Remote MCP and Local Tool Plugin Module for oasis
    DEPENDS:=+oasis
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis-mod-tools/install
	$(INSTALL_DIR) $(1)$(OASIS_MERGE_CONFIG_DIR)
	$(INSTALL_DIR) $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service
	$(INSTALL_DATA) ./files/etc/oasis/tool/tool.config $(1)$(OASIS_MERGE_CONFIG_DIR)
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/anthropic.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/anthropic.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/google.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/google.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/ollama.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/ollama.lua
	$(INSTALL_BIN) ./files/usr/lib/lua/oasis/remote/mcp/service/openai.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/openai.lua
endef

define Package/oasis-mod-tools/postinst
	#!/bin/sh
	uci import -m /etc/oasis/tool/tool.config oasis
	uci commit oasis
endef

$(eval $(call BuildPackage,oasis-mod-tools))
