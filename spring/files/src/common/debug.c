#include <stdio.h>
#include <stdarg.h>
#include <sys/sysinfo.h>
#include "../springd/util/uci.h"

#define DEBUG_LOG_FILE "/tmp/spring"

int is_debug_enabled() {
    char value[256];
    uci_get_option("spring.debug.enable", value);
    return (value != NULL && strcmp(value, "1") == 0);
}

void DEBUG_LOG(const char *format, ...) {

    bool is_debug = uci_get_bool_option("spring.debug.enable");

    if (!is_debug) {
        return;
    }

    FILE *log_file = fopen(DEBUG_LOG_FILE, "a");
    if (log_file == NULL) {
        perror("Failed to open log file");
        return;
    }

    // Get system uptime
    struct sysinfo info;
    if (sysinfo(&info) == 0) {
        fprintf(log_file, "[%ld]\t", info.uptime);
    }

    va_list args;
    va_start(args, format);

    // Print the formatted message
    vfprintf(log_file, format, args);

    va_end(args);

    fclose(log_file);
}