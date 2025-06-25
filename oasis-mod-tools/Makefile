include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-mod-tools
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

LIBRARY_DIR = /usr/lib/lua
UCI_CONFIG_DIR = /etc/config

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
	$(INSTALL_DIR) $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service
	$(INSTALL_DATA) ./files/usr/lib/lua/oasis/remote/mcp/service/anthropic.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/anthropic.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/oasis/remote/mcp/service/google.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/google.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/oasis/remote/mcp/service/ollama.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/ollama.lua
	$(INSTALL_DATA) ./files/usr/lib/lua/oasis/remote/mcp/service/openai.lua $(1)$(LIBRARY_DIR)/oasis/remote/mcp/service/openai.lua
endef

$(eval $(call BuildPackage,oasis-mod-tools))
