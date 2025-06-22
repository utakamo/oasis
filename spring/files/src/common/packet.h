#ifndef PACKET_H
#define PACKET_H

#include <stdint.h>

// 仮のパケット構造定義
typedef struct {
    uint32_t id;       // パケットID
    uint16_t type;     // パケットタイプ
    char data[128];    // データフィールド
} Packet;

#endif // PACKET_H
