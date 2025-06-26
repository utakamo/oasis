#include "packet.h"
#include "debug.h"
#include <string.h>

void init_packet(Packet *packet, uint32_t id, uint16_t type, const char *data) {
    if (packet == NULL || data == NULL) {
        return;
    }

    packet->id = id;
    packet->type = type;
    strncpy(packet->data, data, sizeof(packet->data) - 1);
    packet->data[sizeof(packet->data) - 1] = '\0';
}

void print_packet(const Packet *packet) {
    if (packet == NULL) {
        return;
    }

    DEBUG_LOG("Packet ID: %u\n", packet->id);
    DEBUG_LOG("Packet Type: %u\n", packet->type);
    DEBUG_LOG("Packet Data: %s\n", packet->data);
}
