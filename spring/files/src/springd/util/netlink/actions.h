/*
 * Copyright (C) 2024 utakamo <contact@utakamo.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License version 2.1
 * as published by the Free Software Foundation
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 */

#ifndef NETLINK_ACTIONS_H
#define NETLINK_ACTIONS_H

#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <net/if.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/if.h>
#include <linux/if_link.h>
#include <linux/if_addr.h>
#include <linux/if_link.h>
#include <linux/if_arp.h>
#include <sys/socket.h>
#include <lualib.h>
#include <lauxlib.h>
#include <lua.h>

// Function prototypes for netlink actions
int set_interface_state(lua_State *);
int rename_interface(lua_State *);
int set_interface_mtu(lua_State *);
int set_interface_ip(lua_State *);
int set_interface_flags(lua_State *);
int delete_interface(lua_State *);
int set_link_state(lua_State *);
int set_broadcast_address(lua_State *);
int set_subnet_mask(lua_State *);
int add_arp_entry(lua_State *);

#endif // NETLINK_ACTIONS_H
