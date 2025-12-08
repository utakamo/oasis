include $(TOPDIR)/rules.mk

PKG_NAME:=oasis-mod-spring
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_BUILD_DIR_1:=$(BUILD_DIR)/$(PKG_NAME)$(PKG_VERSION)-$(PKG_RELEASE)
PKG_BUILD_DIR_2:=$(BUILD_DIR)/$(PKG_NAME)d$(PKG_VERSION)-$(PKG_RELEASE)

SPRING_SOURCE_DIR = ./files/src/spring
SPRINGD_SOURCE_DIR =./files/src/springd
PKG_BUILD_DEPENDS:= +liblua +libpthread
TARGET_LDFLAGS += -luci -llua -lpthread -lm

APP_DIR = /usr/bin
LIBRARY_DIR = /usr/lib/lua
UCI_CONFIG_DIR = /etc/config
SPRING_DIR = /etc/spring
INIT_DIR = /etc/init.d
SCRIPTS_DIR = $(SPRING_DIR)/scripts

include $(INCLUDE_DIR)/package.mk

define Package/oasis-mod-spring
    CATEGORY:=utakamo
    SECTION:=utakamo
    TITLE:= Automaton System for Oasis Integration
    DEPENDS:=+oasis +luci-app-oasis
    PKGARCH:=all
endef

define Build/Prepare
endef

define Build/Compile
	$(MAKE) -C $(SPRING_SOURCE_DIR)/ \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)"

	$(MAKE) -C $(SPRINGD_SOURCE_DIR)/ \
		CC="$(TARGET_CC)" \
		CFLAGS="$(TARGET_CFLAGS)" \
		LDFLAGS="$(TARGET_LDFLAGS)"
endef

define Package/oasis-mod-spring/install
		$(INSTALL_DIR) $(1)$(APP_DIR)
		$(INSTALL_DIR) $(1)$(INIT_DIR)
		$(INSTALL_DIR) $(1)$(SCRIPTS_DIR)
		$(INSTALL_DIR) $(1)$(LIBRARY_DIR)/spring/matrix
		$(INSTALL_DIR) $(1)$(UCI_CONFIG_DIR)
		$(INSTALL_DATA) ./files/etc/config/spring.config $(1)$(UCI_CONFIG_DIR)/spring
		$(INSTALL_BIN) $(SPRING_SOURCE_DIR)/spring $(1)$(APP_DIR)/spring
		$(INSTALL_BIN) $(SPRINGD_SOURCE_DIR)/springd $(1)$(APP_DIR)/springd
		$(INSTALL_BIN) ./files/etc/init.d/spring.init $(1)$(INIT_DIR)/spring
		$(INSTALL_BIN) ./files/usr/lib/lua/spring/phase.lua $(1)$(LIBRARY_DIR)/spring
		$(INSTALL_BIN) ./files/usr/lib/lua/spring/matrix/master.lua $(1)$(LIBRARY_DIR)/spring/matrix
endef

define Package/oasis-mod-spring/postinst
	#!/bin/sh
	uci set oasis.support.spring=1
	if [ $? -eq 0 ]; then
		uci commit oasis
	fi
	#TODO: Check below
	#mkdir -p /tmp/oasis
	#touch /tmp/oasis/reboot_required
endef

define Package/oasis-mod-spring/postinst
	#!/bin/sh
	mkdir -p /tmp/oasis
	touch /tmp/oasis/reboot_required_for_oasis-mod-spring
endef

$(eval $(call BuildPackage,oasis-mod-spring))