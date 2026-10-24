include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-mod-agent
PKG_VERSION:=1.1.0
PKG_RELEASE:=1

APP_DIR := /usr/lib/lua/oasis/agent

include $(INCLUDE_DIR)/package.mk

define Package/oasis-mod-agent
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= Agent mode plugin for Oasis
    DEPENDS:=+oasis-mod-tool
    EXTRA_DEPENDS:=oasis (>=3.2.6-r26), oasis-mod-tool (>=1.1.1-r18)
    PKGARCH:=all
endef

define Build/Compile
endef

define Package/oasis-mod-agent/install
	$(INSTALL_DIR) $(1)$(APP_DIR)
	$(INSTALL_DATA) ./files/usr/lib/lua/oasis/agent/*.lua $(1)$(APP_DIR)/
	$(INSTALL_DIR) $(1)/usr/libexec/rpcd $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DIR) $(1)/etc/oasis/tool-manifest.d $(1)/usr/bin $(1)/etc/init.d
	$(INSTALL_BIN) ./files/usr/libexec/rpcd/oasis.tool.manager $(1)/usr/libexec/rpcd/
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/oasis-mod-agent.json $(1)/usr/share/rpcd/acl.d/
	$(INSTALL_DATA) ./files/etc/oasis/tool-manifest.d/lua.oasis.tool.manager.json $(1)/etc/oasis/tool-manifest.d/
	$(INSTALL_BIN) ./files/usr/bin/oasis_agent_setup $(1)/usr/bin/
	$(INSTALL_BIN) ./files/etc/init.d/oasis_agent $(1)/etc/init.d/
endef

define Package/oasis-mod-agent/postinst
	#!/bin/sh
	[ -n "$${IPKG_INSTROOT}" ] && exit 0
	/usr/bin/oasis_agent_setup initialize-package || exit 1
	mkdir -p /tmp/oasis
	touch /tmp/oasis/reboot_required_for_oasis-mod-agent
endef

define Package/oasis-mod-agent/prerm
	#!/bin/sh
	[ -n "$${IPKG_INSTROOT}" ] && exit 0
	[ "$${PKG_UPGRADE}" = "1" ] && exit 0
	[ "$$1" = "upgrade" ] && exit 0
	/usr/bin/oasis_agent_setup remove || exit 1
endef

$(eval $(call BuildPackage,oasis-mod-agent))
