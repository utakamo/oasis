#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <pthread.h>
#include <lualib.h>
#include <lauxlib.h>
#include <lua.h>
#include <time.h>
#include "./util/ioctl/events.h"
#include "./util/ioctl/actions.h"
#include "./util/netlink/events.h"
#include "./util/netlink/actions.h"
#include "./util/uci.h"
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include "../common/debug.h"

bool is_terminate = false;

void daemonize(void) {
    pid_t pid;

    pid = fork();
    if (pid < 0) {
        exit(EXIT_FAILURE);
    }
    if (pid > 0) {
        exit(EXIT_SUCCESS);
    }

    if (setsid() < 0) {
        exit(EXIT_FAILURE);
    }

    signal(SIGHUP, SIG_IGN);

    pid = fork();
    if (pid < 0) {
        exit(EXIT_FAILURE);
    }
    if (pid > 0) {
        exit(EXIT_SUCCESS);
    }

    umask(0);

    if (chdir("/") < 0) {
        exit(EXIT_FAILURE);
    }

    for (int x = sysconf(_SC_OPEN_MAX); x>=0; x--) {
        close(x);
    }

    open("/dev/null", O_RDWR);
    if (dup(0) < 0) {
        exit(EXIT_FAILURE);
    }
    if (dup(0) < 0) {
        exit(EXIT_FAILURE);
    }
}

void handle_signal(int sig) {
    switch(sig) {
        case SIGTERM:
            DEBUG_LOG("[handle_signal] SIGTERM SIGNAL!!\n");
            is_terminate = true;
            break;
        case SIGUSR1:
            // printf("SIGUSR1 received\n");
            break;
        case SIGUSR2:
            // printf("SIGUSR2 received\n");
            break;
        default:
            break;
    }
}

void handle_sigterm(int signum) {
    FILE *file = fopen("/tmp/spring/sigterm", "w");
    if (file) {
        fprintf(file, "SIGTERM received\n");
        fclose(file);
    } else {
        perror("Failed to create /tmp/spring/sigterm");
    }
    exit(0);
}

void setup_signal_handlers(void) {
    struct sigaction sa;
    sa.sa_handler = handle_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;

    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGUSR1, &sa, NULL);
    sigaction(SIGUSR2, &sa, NULL);
}

void* send_message_process(void* arg) {
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    if (luaL_loadfile(L, "/home/kamo/oasis/main.lua") || lua_pcall(L, 0, 0, 0)) {
        lua_close(L);
        return NULL;
    }

    for (;;) {
        if (is_terminate) {
            break;
        }

        sleep(1);
    }

    lua_close(L);
    return NULL;
}

void register_lua_functions(lua_State *L) {
    lua_register(L, "add_route", add_route);
    lua_register(L, "delete_route", delete_route);
    lua_register(L, "get_ifname_from_idx", get_ifname_from_idx);
    lua_register(L, "get_if_ipv4", get_if_ipv4);
    lua_register(L, "get_netmask", get_netmask);
    lua_register(L, "get_mtu", get_mtu);
    lua_register(L, "get_mac_addr", get_mac_addr);
    lua_register(L, "get_if_idx", get_if_idx);
    lua_register(L, "get_if_ipv6", get_if_ipv6);
    lua_register(L, "get_if_ipv6_from_idx", get_if_ipv6_from_idx);
    lua_register(L, "get_if_ipv6_from_name", get_if_ipv6_from_name);
    lua_register(L, "set_interface_state", set_interface_state);
    lua_register(L, "rename_interface", rename_interface);
    lua_register(L, "set_interface_mtu", set_interface_mtu);
    lua_register(L, "set_interface_ip", set_interface_ip);
    lua_register(L, "set_interface_flags", set_interface_flags);
    lua_register(L, "delete_interface", delete_interface);
    lua_register(L, "set_link_state", set_link_state);
    lua_register(L, "set_broadcast_address", set_broadcast_address);
    lua_register(L, "set_subnet_mask", set_subnet_mask);
    lua_register(L, "add_arp_entry", add_arp_entry);
}

// Call register_lua_functions before loading phase.lua
void load_phase_lua(lua_State *L) {
    if (luaL_dofile(L, "/usr/lib/lua/spring/phase.lua") != 0) {
        fprintf(stderr, "Error loading phase.lua: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }
}

void* matrix_ctrl_process(void *arg) {

    DEBUG_LOG("[matrix_ctr_process] start\n");

    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    register_lua_functions(L);

    if (luaL_dofile(L, "/usr/lib/lua/spring/phase.lua") != 0) {
        DEBUG_LOG("Error loading phase.lua\n");
        fprintf(stderr, "Error loading phase.lua: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
    }

    lua_getglobal(L, "test_exec_allevents");
    if (lua_isfunction(L, -1)) {
        if (lua_pcall(L, 0, 0, 0) != 0) {
            DEBUG_LOG("Error running test_exec_allevents\n");
            fprintf(stderr, "Error running test_exec_allevents: %s\n", lua_tostring(L, -1));
            lua_pop(L, 1);
        }
    } else {
        lua_pop(L, 1);
        DEBUG_LOG("test_exec_allevents is not a function\n");
        fprintf(stderr, "test_exec_allevents is not a function\n");
    }

    for (;;) {

        if (is_terminate) {
            DEBUG_LOG("[matrix_ctr_process] terminate\n");
            break;
        }
        
        DEBUG_LOG("[matrix_ctr_process] loop ... \n");

        sleep(1);
    }

    lua_close(L);
    return NULL;
}

void* handle_unix_socket_communication(void* arg) {
    int server_fd, client_fd;
    struct sockaddr_un addr;
    char buffer[256];

    // Create socket
    server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd == -1) {
        perror("socket");
        return NULL;
    }

    // Set up the address structure
    memset(&addr, 0, sizeof(struct sockaddr_un));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, "/tmp/springd.sock", sizeof(addr.sun_path) - 1);

    // Bind the socket
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(struct sockaddr_un)) == -1) {
        perror("bind");
        close(server_fd);
        return NULL;
    }

    // Listen for connections
    if (listen(server_fd, 5) == -1) {
        perror("listen");
        close(server_fd);
        return NULL;
    }

    // set non blocking mode
    int flags = fcntl(server_fd, F_GETFL, 0);
    if (flags != -1) {
        fcntl(server_fd, F_SETFL, flags | O_NONBLOCK);
    }

    printf("Server listening on /tmp/springd.sock\n");

    for (;;) {

        if (is_terminate) {
            DEBUG_LOG("[handle_unix_socket_communication] terminate\n");
            break;
        }

        DEBUG_LOG("[handle_unix_socket_communication] loop ...\n");
        sleep(1);

        // Accept a connection
        client_fd = accept(server_fd, NULL, NULL);
        if (client_fd == -1) {
            perror("accept");
            continue;
        }

        // Receive data
        ssize_t num_bytes = read(client_fd, buffer, sizeof(buffer) - 1);
        if (num_bytes > 0) {
            buffer[num_bytes] = '\0';
            printf("Received: %s\n", buffer);
        } else if (num_bytes == -1) {
            perror("read");
        }

        // Close the client connection
        close(client_fd);
    }

    // Close the server socket
    close(server_fd);
    return NULL;
}

void* watchdog_process(void* arg) {

    for (;;) {

        if (is_terminate) {
            DEBUG_LOG("[watchdog_process] terminate\n");
            break;
        }

        sleep(1);
    }
    return NULL;
}

unsigned long get_system_uptime() {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
        return ts.tv_sec;
    }
    return 0; // エラー時は0を返す
}

// 各スレッドの無限ループ内での時刻処理
void thread_function() {
    unsigned long current_time, pre_time;
    current_time = pre_time = get_system_uptime();

    for (;;) {
        current_time = get_system_uptime();
        // ここで必要な処理を実行
        pre_time = current_time;
        sleep(1); // 1秒間隔
    }
}

int main(void) {
    daemonize();
    setup_signal_handlers();

    DEBUG_LOG("[main] create threads\n");

    pthread_t message_sender_thread, matrix_ctrl_thread, recv_cmd_thread, watchdog_thread;
    pthread_create(&message_sender_thread, NULL, send_message_process, NULL);
    pthread_create(&matrix_ctrl_thread, NULL, matrix_ctrl_process, NULL);
    pthread_create(&recv_cmd_thread, NULL, handle_unix_socket_communication, NULL);
    pthread_create(&watchdog_thread, NULL, watchdog_process, NULL);

    for (;;) {

        if (is_terminate) {
            DEBUG_LOG("[main] terminate\n");
            break;
        }

        sleep(1);
    }

    pthread_join(message_sender_thread, NULL);
    pthread_join(matrix_ctrl_thread, NULL);
    pthread_join(recv_cmd_thread, NULL);
    pthread_join(watchdog_thread, NULL);

    return 0;
}