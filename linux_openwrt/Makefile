# SPDX-License-Identifier: GPL-2.0-only
#
# Copyright (C) 2026 BlueWave Projects and Services  <licence@blue-wave.net>
#

include $(TOPDIR)/rules.mk

PKG_NAME:=apmond
PKG_VERSION:=0.1.0
PKG_RELEASE:=12

PKG_MAINTAINER:=Rob White <rob@blue-wave.net>
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=LICENSE

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/opennds/apmond/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=#shasum -a 256 of tar.gz of source files goes here

include $(INCLUDE_DIR)/package.mk

define Package/apmond
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Access Point Monitoring Daemon
  PKGARCH:=all
  DEPENDS:=+luci-ssl
  # opkg records CONFLICTS; OpenWrt's apk packaging ignores CONFLICTS, so express it as an apk "!" dependency
  CONFLICTS:=mesh11sd
  ifneq ($(CONFIG_USE_APK),)
    EXTRA_DEPENDS:=!mesh11sd (>=0)
  endif
  URL:=https://github.com/opennds/apmond
endef

define Package/apmond/description
  ApmonD collects access point usage data (wireless and wired clients,
  node status and wireless chipset information) on access points and
  sends it to a central collector, where the latest report from each
  access point is kept.
  It is a standalone port of the apmond functionality of mesh11sd,
  for networks that do not use mesh11sd.
  Every node runs the same configuration: the router is detected
  automatically and becomes the collector over IPv6 ULA, derived from a
  shared seed, as in mesh11sd.
  It is fully compatible with static UCI and LuCI configuration.
  A command line interface is provided.
endef

define Package/apmond/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_DIR) $(1)/www/cgi-bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/src/apmond $(1)/usr/sbin
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/linux_openwrt/apmond/files/etc/config/apmond $(1)/etc/config/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/linux_openwrt/apmond/files/etc/init.d/apmond $(1)/etc/init.d/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/linux_openwrt/apmond/files/www/cgi-bin/apmon.cgi $(1)/www/cgi-bin/
endef

define Package/apmond/conffiles
/etc/config/apmond
endef

define Package/apmond/postinst
#!/bin/sh
# Appended after default_postinst, which has already run "/etc/init.d/apmond start".
# On an upgrade procd ignores that start (same command line), so the old code keeps running: restart it.
# Fresh install: PKG_UPGRADE is unset, default_postinst started it once. Image build: IPKG_INSTROOT is set.
if [ -z "$${IPKG_INSTROOT}" ] && [ "$${PKG_UPGRADE}" = "1" ] && /etc/init.d/apmond running; then
	/etc/init.d/apmond restart
fi
endef

define Build/Compile
endef

$(eval $(call BuildPackage,apmond))
