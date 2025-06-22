#ifndef IOCTL_EVENTS_H
#define IOCTL_EVENTS_H

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/route.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <linux/if_ether.h>
#include <linux/if_arp.h>
#include <lua.h>
#include <lauxlib.h>
#include "../uci.h"
#include <lua.h>

int get_ifname_from_idx(lua_State *);
int get_if_ipv4(lua_State *);
int get_netmask(lua_State *);
int get_mtu(lua_State *);
int get_mac_addr(lua_State *);
int get_if_idx(lua_State *);
int get_if_ipv6(lua_State *);
int get_if_ipv6_from_idx(lua_State *);
int get_if_ipv6_from_name(lua_State *);
#endif // IOCTL_EVENTS_H