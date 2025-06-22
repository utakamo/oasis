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

#include "./actions.h"
#include "../errors.h"
#include <lua.h>
#include <lauxlib.h>

/*
 * Enable or disable a network interface.
 *
 * usage:
 * set_interface_state("eth0", 1); // Enable
 * set_interface_state("eth0", 0); // Disable
 */
int set_interface_state(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    int state = luaL_checkinteger(L, 2);

    int sock_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct {
        struct nlmsghdr nlh;
        struct ifinfomsg ifm;
    } request;

    memset(&request, 0, sizeof(request));
    request.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg));
    request.nlh.nlmsg_type = RTM_NEWLINK;
    request.nlh.nlmsg_flags = NLM_F_REQUEST;
    request.ifm.ifi_family = AF_UNSPEC;
    request.ifm.ifi_index = if_nametoindex(ifname);
    request.ifm.ifi_flags = state ? IFF_UP : 0;
    request.ifm.ifi_change = IFF_UP;

    if (send(sock_fd, &request, request.nlh.nlmsg_len, 0) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to send netlink message");
    }

    close(sock_fd);
    return 0;
}

/*
 * Change the name of a network interface.
 *
 * usage:
 * rename_interface("eth0", "newname");
 */
int rename_interface(lua_State *L) {
    const char *old_name = luaL_checkstring(L, 1);
    const char *new_name = luaL_checkstring(L, 2);

    int sock_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct {
        struct nlmsghdr nlh;
        struct ifinfomsg ifm;
        char buffer[256];
    } request;

    memset(&request, 0, sizeof(request));
    request.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg) + strlen(new_name) + 1);
    request.nlh.nlmsg_type = RTM_NEWLINK;
    request.nlh.nlmsg_flags = NLM_F_REQUEST;
    request.ifm.ifi_family = AF_UNSPEC;
    request.ifm.ifi_index = if_nametoindex(old_name);

    strcpy(request.buffer, new_name);

    if (send(sock_fd, &request, request.nlh.nlmsg_len, 0) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to send netlink message");
    }

    close(sock_fd);
    return 0;
}

/*
 * Set the MTU of a network interface.
 *
 * usage:
 * set_interface_mtu("eth0", 1500);
 */
int set_interface_mtu(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    int mtu = luaL_checkinteger(L, 2);

    int sock_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct {
        struct nlmsghdr nlh;
        struct ifinfomsg ifm;
        int mtu;
    } request;

    memset(&request, 0, sizeof(request));
    request.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg) + sizeof(int));
    request.nlh.nlmsg_type = RTM_NEWLINK;
    request.nlh.nlmsg_flags = NLM_F_REQUEST;
    request.ifm.ifi_family = AF_UNSPEC;
    request.ifm.ifi_index = if_nametoindex(ifname);
    request.mtu = mtu;

    if (send(sock_fd, &request, request.nlh.nlmsg_len, 0) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to send netlink message");
    }

    close(sock_fd);
    return 0;
}

/*
 * Set the IP address of a network interface.
 *
 * usage:
 * set_interface_ip("eth0", "192.168.1.100");
 */
int set_interface_ip(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    const char *ip_address = luaL_checkstring(L, 2);

    int sock_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct {
        struct nlmsghdr nlh;
        struct ifaddrmsg ifa;
        char buffer[256];
    } request;

    memset(&request, 0, sizeof(request));
    request.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifaddrmsg) + strlen(ip_address) + 1);
    request.nlh.nlmsg_type = RTM_NEWADDR;
    request.nlh.nlmsg_flags = NLM_F_REQUEST;
    request.ifa.ifa_family = AF_INET;
    request.ifa.ifa_index = if_nametoindex(ifname);

    strcpy(request.buffer, ip_address);

    if (send(sock_fd, &request, request.nlh.nlmsg_len, 0) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to send netlink message");
    }

    close(sock_fd);
    return 0;
}

/*
 * Set flags for a network interface.
 *
 * usage:
 * set_interface_flags("eth0", IFF_PROMISC, 0); // Enable promiscuous mode
 * set_interface_flags("eth0", 0, IFF_PROMISC); // Disable promiscuous mode
 */
int set_interface_flags(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    unsigned int flags_to_set = luaL_checkinteger(L, 2);
    unsigned int flags_to_clear = luaL_checkinteger(L, 3);

    int sock_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct {
        struct nlmsghdr nlh;
        struct ifinfomsg ifm;
    } request;

    memset(&request, 0, sizeof(request));
    request.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg));
    request.nlh.nlmsg_type = RTM_NEWLINK;
    request.nlh.nlmsg_flags = NLM_F_REQUEST;
    request.ifm.ifi_family = AF_UNSPEC;
    request.ifm.ifi_index = if_nametoindex(ifname);
    request.ifm.ifi_flags |= flags_to_set;
    request.ifm.ifi_flags &= ~flags_to_clear;
    request.ifm.ifi_change = flags_to_set | flags_to_clear;

    if (send(sock_fd, &request, request.nlh.nlmsg_len, 0) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to send netlink message");
    }

    close(sock_fd);
    return 0;
}

/*
 * Delete a network interface.
 *
 * usage:
 * delete_interface("eth0");
 */
int delete_interface(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);

    int sock_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct {
        struct nlmsghdr nlh;
        struct ifinfomsg ifm;
    } request;

    memset(&request, 0, sizeof(request));
    request.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg));
    request.nlh.nlmsg_type = RTM_DELLINK;
    request.nlh.nlmsg_flags = NLM_F_REQUEST;
    request.ifm.ifi_family = AF_UNSPEC;
    request.ifm.ifi_index = if_nametoindex(ifname);

    if (send(sock_fd, &request, request.nlh.nlmsg_len, 0) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to send netlink message");
    }

    close(sock_fd);
    return 0;
}

/*
 * Change the link state of a network interface.
 *
 * usage:
 * set_link_state("eth0", 1); // Bring link up
 * set_link_state("eth0", 0); // Bring link down
 */
int set_link_state(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    int state = luaL_checkinteger(L, 2);

    int sock_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct {
        struct nlmsghdr nlh;
        struct ifinfomsg ifm;
    } request;

    memset(&request, 0, sizeof(request));
    request.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg));
    request.nlh.nlmsg_type = RTM_NEWLINK;
    request.nlh.nlmsg_flags = NLM_F_REQUEST;
    request.ifm.ifi_family = AF_UNSPEC;
    request.ifm.ifi_index = if_nametoindex(ifname);
    request.ifm.ifi_flags = state ? IFF_RUNNING : 0;
    request.ifm.ifi_change = IFF_RUNNING;

    if (send(sock_fd, &request, request.nlh.nlmsg_len, 0) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to send netlink message");
    }

    close(sock_fd);
    return 0;
}

/*
 * Set the broadcast address of a network interface.
 *
 * usage:
 * set_broadcast_address("eth0", "192.168.1.255");
 */
int set_broadcast_address(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    const char *bcast_addr = luaL_checkstring(L, 2);

    int sock_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct {
        struct nlmsghdr nlh;
        struct ifaddrmsg ifa;
        char buffer[256];
    } request;

    memset(&request, 0, sizeof(request));
    request.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifaddrmsg) + strlen(bcast_addr) + 1);
    request.nlh.nlmsg_type = RTM_NEWADDR;
    request.nlh.nlmsg_flags = NLM_F_REQUEST;
    request.ifa.ifa_family = AF_INET;
    request.ifa.ifa_index = if_nametoindex(ifname);

    strcpy(request.buffer, bcast_addr);

    if (send(sock_fd, &request, request.nlh.nlmsg_len, 0) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to send netlink message");
    }

    close(sock_fd);
    return 0;
}

/*
 * Set the subnet mask of a network interface.
 *
 * usage:
 * set_subnet_mask("eth0", "255.255.255.0");
 */
int set_subnet_mask(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    const char *netmask = luaL_checkstring(L, 2);

    int sock_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct {
        struct nlmsghdr nlh;
        struct ifaddrmsg ifa;
        char buffer[256];
    } request;

    memset(&request, 0, sizeof(request));
    request.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifaddrmsg) + strlen(netmask) + 1);
    request.nlh.nlmsg_type = RTM_NEWADDR;
    request.nlh.nlmsg_flags = NLM_F_REQUEST;
    request.ifa.ifa_family = AF_INET;
    request.ifa.ifa_index = if_nametoindex(ifname);

    strcpy(request.buffer, netmask);

    if (send(sock_fd, &request, request.nlh.nlmsg_len, 0) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to send netlink message");
    }

    close(sock_fd);
    return 0;
}

/*
 * Add a static ARP entry to a network interface.
 *
 * usage:
 * add_arp_entry("eth0", "192.168.1.1", "AA:BB:CC:DD:EE:FF");
 */
int add_arp_entry(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    const char *ip_addr = luaL_checkstring(L, 2);
    const char *mac_addr = luaL_checkstring(L, 3);

    int sock_fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct {
        struct nlmsghdr nlh;
        struct ndmsg ndm;
        char buffer[256];
    } request;

    memset(&request, 0, sizeof(request));
    request.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ndmsg) + strlen(ip_addr) + strlen(mac_addr) + 2);
    request.nlh.nlmsg_type = RTM_NEWNEIGH;
    request.nlh.nlmsg_flags = NLM_F_REQUEST;
    request.ndm.ndm_family = AF_INET;
    request.ndm.ndm_ifindex = if_nametoindex(ifname);
    request.ndm.ndm_state = NUD_PERMANENT;

    snprintf(request.buffer, sizeof(request.buffer), "%s %s", ip_addr, mac_addr);

    if (send(sock_fd, &request, request.nlh.nlmsg_len, 0) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to send netlink message");
    }

    close(sock_fd);
    return 0;
}
