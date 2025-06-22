# OpenWrt パッケージ用のMakefile

all: springd

CC = gcc
CFLAGS = -Wall -O2
LDFLAGS = -luci -llua -lpthread -lm

DEPS = $(wildcard util/*.h util/ioctl/*.h util/netlink/*.h ../common/*.h)
SRC = $(wildcard *.c util/*.c util/ioctl/*.c util/netlink/*.c ../common/*.c)

OBJ = $(patsubst %.c, %.o, $(SRC))

%.o: %.c $(DEPS)
	$(CC) -c -o $@ $< $(CFLAGS)

springd: $(OBJ)
	$(CC) -o $@ $^ $(LDFLAGS)

.PHONY: clean

clean:
	rm -f springd datacheck ./*.o ./util/*.o ./util/ioctl/*.o ./util/netlink/*.o
