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

#include "actions.h"
#include "../errors.h"
#include <lua.h>
#include <lauxlib.h>

/*
* IOCTL: SIOCADDRT
* This process is equivalent to the ip route add or route add command in Linux commands.
* These commands are used to add new routes to the kernel routing table.
* The result of this function can be checked with "ip route show" command.
*
* usage: add_route("192.168.1.0", "192.168.1.1", "255.255.255.0", "eth0");
* ---> ip route add 192.168.1.0/24 via 192.168.1.1 dev eth0
*/
int add_route(lua_State *L) {
    const char *dest = luaL_checkstring(L, 1);
    const char *netmask = luaL_checkstring(L, 2);
    const char *gateway = luaL_checkstring(L, 3);
    const char *ifname = luaL_checkstring(L, 4);

    int sockfd;
    struct rtentry route;
    struct sockaddr_in *addr;

    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    memset(&route, 0, sizeof(route));

    addr = (struct sockaddr_in *)&route.rt_dst;
    addr->sin_family = AF_INET;
    if (inet_pton(AF_INET, dest, &addr->sin_addr) <= 0) {
        close(sockfd);
        return luaL_error(L, "Invalid destination address");
    }

    addr = (struct sockaddr_in *)&route.rt_genmask;
    addr->sin_family = AF_INET;
    if (inet_pton(AF_INET, netmask, &addr->sin_addr) <= 0) {
        close(sockfd);
        return luaL_error(L, "Invalid netmask");
    }

    addr = (struct sockaddr_in *)&route.rt_gateway;
    addr->sin_family = AF_INET;
    if (inet_pton(AF_INET, gateway, &addr->sin_addr) <= 0) {
        close(sockfd);
        return luaL_error(L, "Invalid gateway address");
    }

    route.rt_flags = RTF_UP | RTF_GATEWAY;
    route.rt_dev = (char *)ifname;

    if (ioctl(sockfd, SIOCADDRT, &route) < 0) {
        close(sockfd);
        return luaL_error(L, "Failed to add route");
    }

    close(sockfd);
    return 0;
}

/*
* IOCTL: SIOCDELRT
* This process is equivalent to the ip route delete or route delete command in Linux commands.
* These commands are used to remove the target route from the kernel routing table.
* The result of this function can be checked with the ip route show command.
*
* usage: delete_route("192.168.1.0", "255.255.255.0", "eth0");
* ---> ip route del 192.168.1.0/24 dev eth0
*/
int delete_route(lua_State *L) {
    const char *dest = luaL_checkstring(L, 1);
    const char *netmask = luaL_checkstring(L, 2);
    const char *ifname = luaL_checkstring(L, 3);

    int sockfd;
    struct rtentry route;
    struct sockaddr_in *addr;

    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    memset(&route, 0, sizeof(route));

    addr = (struct sockaddr_in *)&route.rt_dst;
    addr->sin_family = AF_INET;
    if (inet_pton(AF_INET, dest, &addr->sin_addr) <= 0) {
        close(sockfd);
        return luaL_error(L, "Invalid destination address");
    }

    addr = (struct sockaddr_in *)&route.rt_genmask;
    addr->sin_family = AF_INET;
    if (inet_pton(AF_INET, netmask, &addr->sin_addr) <= 0) {
        close(sockfd);
        return luaL_error(L, "Invalid netmask");
    }

    route.rt_dev = (char *)ifname;

    if (ioctl(sockfd, SIOCDELRT, &route) < 0) {
        close(sockfd);
        return luaL_error(L, "Failed to delete route");
    }

    close(sockfd);
    return 0;
}