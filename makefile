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
SRCS := main.c keeloq.c speed.c attacks/polygen.c
OBJS := main.o keeloq.o speed.o polygen.o

# Default target
all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

main.o: main.c keeloq.h speed.h attacks/polygen.h
	$(CC) $(CFLAGS) -c main.c

keeloq.o: keeloq.c keeloq.h
	$(CC) $(CFLAGS) -c keeloq.c

speed.o: speed.c speed.h keeloq.h
	$(CC) $(CFLAGS) -c speed.c

polygen.o: attacks/polygen.c attacks/polygen.h
	$(CC) $(CFLAGS) -c attacks/polygen.c

# Build modes
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
	$(PYTHON) attacks/groebner_solver.py

sat:
	$(PYTHON) attacks/sat_solver.py

# Setup
setup-python:
	$(PYTHON) -m pip install -r requirements.txt

# Cleanup
clean:
	rm -f $(OBJS) $(TARGET) mqkeeloq.txt
	rm -rf attacks/__pycache__
	find . -name "*.pyc" -delete

.PHONY: all debug release run speed polygen groebner sat setup-python clean
