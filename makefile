# @H. Hadipour
# April 19, 2019

# compiler
# define the C compiler to use
# for C++ define  CC = g++
CC = gcc
# compiler flags:
# -g    adds debugging information to the executable file
# -Wall turns on most, but not all, compiler warnings
CFLAGS  = -g -Wall
# the build target(s) executable:
TARGET = main 
all: main.o 
	$(CC) $(CFLAGS) -o $(TARGET) main.c keeloq.c speed.c polygen.c
speed: speed.o
	$(CC) $(CFLAGS) -o speed speed.c keeloq.c
polygen: polygen.o
	$(CC) $(CFLAGS) -0 polygen keeloq.c
clean:
	rm *.o $(TARGET)
