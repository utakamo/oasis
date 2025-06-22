#include "events.h"
#include "../errors.h"

int get_ifname_from_idx(lua_State *L) {
    int if_idx = luaL_checkinteger(L, 1);
    const char *ifname = luaL_checkstring(L, 2);
    size_t name_len = luaL_checkinteger(L, 3);

    int sockfd;
    struct ifreq ifr;

    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_ifindex = if_idx;

    if (ioctl(sockfd, SIOCGIFNAME, &ifr) < 0) {
        close(sockfd);
        return luaL_error(L, "Failed to get interface name");
    }

    strncpy((char *)ifname, ifr.ifr_name, name_len - 1);
    ((char *)ifname)[name_len - 1] = '\0';

    close(sockfd);
    return 0;
}

int get_if_ipv4(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    const char *ipv4_addr = luaL_checkstring(L, 2);
    size_t addr_len = luaL_checkinteger(L, 3);

    int sockfd;
    struct ifreq ifr;

    memset((char *)ipv4_addr, '\0', addr_len);

    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(sockfd, SIOCGIFADDR, &ifr) < 0) {
        close(sockfd);
        return luaL_error(L, "Failed to get IPv4 address");
    }

    struct sockaddr_in *ipaddr = (struct sockaddr_in *)&ifr.ifr_addr;
    snprintf((char *)ipv4_addr, addr_len, "%s", inet_ntoa(ipaddr->sin_addr));

    close(sockfd);
    return 0;
}

int get_netmask(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    const char *netmask = luaL_checkstring(L, 2);
    size_t netmask_len = luaL_checkinteger(L, 3);

    int sockfd;
    struct ifreq ifr;
    struct sockaddr_in *netmask_addr;

    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(sockfd, SIOCGIFNETMASK, &ifr) < 0) {
        close(sockfd);
        return luaL_error(L, "Failed to get netmask");
    }

    netmask_addr = (struct sockaddr_in *)&ifr.ifr_netmask;
    snprintf((char *)netmask, netmask_len, "%s", inet_ntoa(netmask_addr->sin_addr));

    close(sockfd);
    return 0;
}

/*
 * Get the MTU of a network interface.
 *
 * usage:
 * int mtu;
 * get_interface_mtu("eth0", &mtu);
 */
int get_interface_mtu(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    int *mtu = (int *)lua_touserdata(L, 2);

    int sock_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(sock_fd, SIOCGIFMTU, &ifr) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to get MTU");
    }

    *mtu = ifr.ifr_mtu;

    close(sock_fd);
    return 0;
}

/*
 * Get the MAC address of a network interface.
 *
 * usage:
 * char mac_addr[18];
 * get_interface_mac("eth0", mac_addr, sizeof(mac_addr));
 */
int get_interface_mac(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    const char *mac_addr = luaL_checkstring(L, 2);
    size_t addr_len = luaL_checkinteger(L, 3);

    int sock_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(sock_fd, SIOCGIFHWADDR, &ifr) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to get MAC address");
    }

    unsigned char *mac = (unsigned char *)ifr.ifr_hwaddr.sa_data;
    snprintf((char *)mac_addr, addr_len, "%02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    close(sock_fd);
    return 0;
}

/*
 * Get the flags of a network interface.
 *
 * usage:
 * short flags;
 * get_interface_flags("eth0", &flags);
 */
int get_interface_flags(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    short *flags = (short *)lua_touserdata(L, 2);

    int sock_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock_fd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(sock_fd, SIOCGIFFLAGS, &ifr) < 0) {
        close(sock_fd);
        return luaL_error(L, "Failed to get interface flags");
    }

    *flags = ifr.ifr_flags;

    close(sock_fd);
    return 0;
}

int get_if_ipv6_from_name(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    const char *ipv6_addr = luaL_checkstring(L, 2);
    size_t addr_len = luaL_checkinteger(L, 3);

    int sockfd;
    struct ifreq ifr;

    memset((char *)ipv6_addr, '\0', addr_len);

    sockfd = socket(AF_INET6, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(sockfd, SIOCGIFADDR, &ifr) < 0) {
        close(sockfd);
        return luaL_error(L, "Failed to get IPv6 address");
    }

    strncpy((char *)ipv6_addr, ifr.ifr_addr.sa_data, addr_len - 1);
    ((char *)ipv6_addr)[addr_len - 1] = '\0';

    close(sockfd);
    return 0;
}

int get_mtu(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    int sockfd;
    struct ifreq ifr;

    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(sockfd, SIOCGIFMTU, &ifr) < 0) {
        close(sockfd);
        return luaL_error(L, "Failed to get MTU");
    }

    close(sockfd);
    lua_pushinteger(L, ifr.ifr_mtu);
    return 1;
}

int get_mac_addr(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    const char *mac_addr = luaL_checkstring(L, 2);
    size_t addr_len = luaL_checkinteger(L, 3);

    int sockfd;
    struct ifreq ifr;

    memset((char *)mac_addr, '\0', addr_len);

    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(sockfd, SIOCGIFHWADDR, &ifr) < 0) {
        close(sockfd);
        return luaL_error(L, "Failed to get MAC address");
    }

    strncpy((char *)mac_addr, ifr.ifr_hwaddr.sa_data, addr_len - 1);
    ((char *)mac_addr)[addr_len - 1] = '\0';

    close(sockfd);
    return 0;
}

int get_if_idx(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    int sockfd;
    struct ifreq ifr;

    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

    if (ioctl(sockfd, SIOCGIFINDEX, &ifr) < 0) {
        close(sockfd);
        return luaL_error(L, "Failed to get interface index");
    }

    close(sockfd);
    lua_pushinteger(L, ifr.ifr_ifindex);
    return 1;
}

int get_if_ipv6(lua_State *L) {
    const char *ifname = luaL_checkstring(L, 1);
    struct ifaddrs *ifaddr, *ifa;
    char addr[INET6_ADDRSTRLEN] = {0};

    if (getifaddrs(&ifaddr) == -1) {
        return luaL_error(L, "getifaddrs failed");
    }

    for (ifa = ifaddr; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr &&
            ifa->ifa_addr->sa_family == AF_INET6 &&
            strcmp(ifa->ifa_name, ifname) == 0) {
            struct sockaddr_in6 *sin6 = (struct sockaddr_in6 *)ifa->ifa_addr;
            if (inet_ntop(AF_INET6, &sin6->sin6_addr, addr, sizeof(addr))) {
                lua_pushstring(L, addr);
                freeifaddrs(ifaddr);
                return 1;
            }
        }
    }
    freeifaddrs(ifaddr);
    lua_pushnil(L);
    return 1;
}

int get_if_ipv6_from_idx(lua_State *L) {
    int if_idx = luaL_checkinteger(L, 1);
    const char *ipv6_addr = luaL_checkstring(L, 2);
    size_t addr_len = luaL_checkinteger(L, 3);

    int sockfd;
    struct ifreq ifr;

    memset((char *)ipv6_addr, '\0', addr_len);

    sockfd = socket(AF_INET6, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        return luaL_error(L, "Socket creation failed");
    }

    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_ifindex = if_idx;

    if (ioctl(sockfd, SIOCGIFADDR, &ifr) < 0) {
        close(sockfd);
        return luaL_error(L, "Failed to get IPv6 address");
    }

    strncpy((char *)ipv6_addr, ifr.ifr_addr.sa_data, addr_len - 1);
    ((char *)ipv6_addr)[addr_len - 1] = '\0';

    close(sockfd);
    return 0;
}