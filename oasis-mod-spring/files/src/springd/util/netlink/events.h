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

#ifndef NETLINK_EVENTS_H
#define NETLINK_EVENTS_H

#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <sys/socket.h> 
#include <net/if.h>
#include <string.h>
#include <lua.h>

#define BUFFER_SIZE 8192

typedef struct netlink_if_list {
    int index;
    char ifname[IFNAMSIZ];
} netlink_if_list;

// Function prototypes for netlink events
void parse_rtattr(lua_State *L);
int netlink_list_if(lua_State *L);

#endif // NETLINK_EVENTS_H
