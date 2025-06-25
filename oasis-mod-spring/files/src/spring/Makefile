# OpenWrt パッケージ用のMakefile

all: spring

CC = gcc
CFLAGS = -Wall -O2

SRC = $(wildcard *.c)

OBJ = $(patsubst %.c, %.o, $(SRC))

%.o: %.c
	$(CC) -c -o $@ $< $(CFLAGS)

datacheck: $(OBJ)
	$(CC) -o $@ $^

.PHONY: clean

clean:
	rm -f spring datacheck ./*.o  ../common/*.o