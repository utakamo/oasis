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

#include "events.h"
#include "../errors.h"
#include <stdio.h>
#include <unistd.h>
#include <lua.h>
#include <lauxlib.h>
#include <net/if.h>


#ifndef IFNAMSIZ
#define IFNAMSIZ 16
#endif

// Ensure IFNAMSIZ is defined properly

void parse_rtattr(lua_State *L) {
    const char *tb = (const char *)lua_touserdata(L, 1);
    int max = luaL_checkinteger(L, 2);
    const char *rta = (const char *)lua_touserdata(L, 3);
    int len = luaL_checkinteger(L, 4);

    // Original function logic
    while (RTA_OK((struct rtattr *)rta, len)) {
        if (((struct rtattr *)rta)->rta_type <= max) {
            ((struct rtattr **)tb)[((struct rtattr *)rta)->rta_type] = (struct rtattr *)rta;
        }
        rta = (const char *)RTA_NEXT((struct rtattr *)rta, len);
    }
}

int netlink_list_if(lua_State *L) {
    const char *list = (const char *)lua_touserdata(L, 1);
    int max_if_num = luaL_checkinteger(L, 2);

    int sock_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct sockaddr_nl addr;
    memset(&addr, 0, sizeof(addr));
    addr.nl_family = AF_NETLINK;

    if (bind(sock_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to bind socket");
    }

    struct {
        struct nlmsghdr nlh;
        struct ifinfomsg ifm;
    } request;

    memset(&request, 0, sizeof(request));
    request.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg));
    request.nlh.nlmsg_type = RTM_GETLINK;
    request.nlh.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    request.ifm.ifi_family = AF_UNSPEC;

    if (send(sock_fd, &request, request.nlh.nlmsg_len, 0) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to send netlink message");
    }

    char buffer[BUFFER_SIZE];
    ssize_t len = recv(sock_fd, buffer, sizeof(buffer), 0);
    if (len < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to receive netlink message");
    }

    int item = 0;
    struct nlmsghdr *nlh = (struct nlmsghdr *)buffer;
    for (; NLMSG_OK(nlh, len); nlh = NLMSG_NEXT(nlh, len)) {
        if (item >= max_if_num) {
            break;
        }

        if (nlh->nlmsg_type == NLMSG_DONE) break;
        if (nlh->nlmsg_type == NLMSG_ERROR) {
            return luaL_error(L, "Netlink response error");
        }

        struct ifinfomsg *ifi = NLMSG_DATA(nlh);
        struct rtattr *tb[IFLA_MAX + 1];
        lua_pushlightuserdata(L, tb);
        lua_pushinteger(L, IFLA_MAX);
        lua_pushlightuserdata(L, IFLA_RTA(ifi));
        lua_pushinteger(L, nlh->nlmsg_len);
        parse_rtattr(L);

        if (tb[IFLA_IFNAME]) {
            strncpy(((netlink_if_list *)list)[item].ifname, RTA_DATA(tb[IFLA_IFNAME]), IFNAMSIZ - 1);
            ((netlink_if_list *)list)[item].ifname[IFNAMSIZ - 1] = '\0';
            ((netlink_if_list *)list)[item].index = ifi->ifi_index;
            item++;
        }
    }

    close(sock_fd);
    return item;
}