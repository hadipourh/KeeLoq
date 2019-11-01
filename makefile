# @H. Hadipour
# April 19, 2019

# main structure of make file commands: 
# target: dependencies
#       action
# Example: 
# output: main.o minor1.o minor2.o
#         g++ -o main main.o minor1.o minor2.o
# Some compiler flags:
# -E                       Preprocess only; do not compile, assemble or link.
# -S                       Compile only; do not assemble or link. (generates an assembly file and stop)
# -c                       Compile and assemble, but do not link. (generates an assembly code and converts it to the machine code by assembler)
# -o <file>                Place the output into <file>. (Links assembled files, and builds an executable file)
# -g    adds debugging information to the executable file
# -Wall turns on most, but not all, compiler warnings
# If you don't use a flag at all, your compiler (gcc here) do the process, compile

# compiler
# define the C compiler to use
# for C++ define  CC = g++
CC = gcc
CFLAGS  = -g -Wall
# the build target(s) executable:
TARGET = main
# If you execute make without a flag, it does the actions under the "all" target by default
all: main.o speed.o polygen.o speed.o keeloq.o
	$(CC) $(CFLAGS) -o $(TARGET) main.o keeloq.o speed.o polygen.o
main: main.c
	$(CC) $(CFLAGS) -c main.c
speed: speed.c
	$(CC) $(CFLAGS) -c speed.c
polygen: polygen.c
	$(CC) $(CFLAGS) -c polygen.c 
keeloq: keeloq.c
	$(CC) $(CFLAGS) -c keeloq.c
clean:
	rm *.o $(TARGET)
