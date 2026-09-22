# KeeLoq Cipher - Makefile
# Author: H. Hadipour

CC       := gcc
PYTHON   := python3
TARGET   := keeloq

# Build mode: debug (default) or release
BUILD    ?= debug

ifeq ($(BUILD),release)
    CFLAGS := -O3 -Wall
else
    CFLAGS := -g -Wall
endif

# Source files
SRCS := main.c keeloq.c speed.c attacks/algebraic/polygen.c
OBJS := main.o keeloq.o speed.o polygen.o

# Default target
all: $(TARGET)

# Cube attack helper targets are delegated to attacks/cube/Makefile.
CUBE_MAKE := $(MAKE) -C attacks/cube

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

main.o: main.c keeloq.h speed.h attacks/algebraic/polygen.h
	$(CC) $(CFLAGS) -c main.c

keeloq.o: keeloq.c keeloq.h
	$(CC) $(CFLAGS) -c keeloq.c

speed.o: speed.c speed.h keeloq.h
	$(CC) $(CFLAGS) -c speed.c

polygen.o: attacks/algebraic/polygen.c attacks/algebraic/polygen.h
	$(CC) $(CFLAGS) -c attacks/algebraic/polygen.c

# Build modes
build: all

debug:
	$(MAKE) BUILD=debug all

release:
	$(MAKE) BUILD=release all

# Run targets
run: $(TARGET)
	./$(TARGET)

speed: $(TARGET)
	./$(TARGET) speed

polygen: $(TARGET)
	./$(TARGET) polygen

# Cryptanalysis (Python)
groebner:
	$(PYTHON) attacks/algebraic/groebner_solver.py

sat:
	$(PYTHON) attacks/algebraic/sat_solver.py

# Cube attack helpers
cube-build:
	$(CUBE_MAKE) build

cube-verify:
	$(CUBE_MAKE) verify ROUNDS="$(ROUNDS)" NKEYS="$(NKEYS)" SEED="$(SEED)" CUBE="$(CUBE)"

cube-dim31:
	$(CUBE_MAKE) dim31 CONST_BIT="$(CONST_BIT)" NKEYS="$(NKEYS)" SEED="$(SEED)" DIM31_ROUNDS="$(DIM31_ROUNDS)" TIMEOUT="$(TIMEOUT)"

# Convenience alias since no other top-level verify target exists.
verify: cube-verify

# Setup
setup-python:
	$(PYTHON) -m pip install -r requirements.txt

# Cleanup
clean:
	rm -f $(OBJS) $(TARGET) mqkeeloq.txt
	rm -rf attacks/__pycache__
	find . -name "*.pyc" -delete

.PHONY: all build debug release run speed polygen groebner sat \
	cube-build cube-verify cube-dim31 verify setup-python clean
