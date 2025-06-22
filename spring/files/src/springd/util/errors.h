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

#ifndef ERRORS_H
#define ERRORS_H

#include <string.h>

#define ERR_SOCKET          1
#define ERR_INET_PTON       2
#define ERR_INET_PTON_DST   3
#define ERR_INET_PTON_GT    4
#define ERR_INET_PTON_MASK  5
#define ERR_IOCTL           6
#define ERR_MAC_FORMAT      7
#define ERR_BIND            8
#define ERR_SEND            9
#define ERR_RECV            10
#define ERR_RESPONSE        11

#define MAX_INTERFACES      128
#define MAX_IFNAME_LEN      256

#endif // ERRORS_H