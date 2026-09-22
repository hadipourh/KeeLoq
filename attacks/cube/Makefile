CC       ?= cc
CFLAGS   ?= -O2 -Wall
LDFLAGS  ?= -lpthread

VENV     ?= ../../venv
PYTHON   := $(shell if [ -x $(VENV)/bin/python ]; then echo $(VENV)/bin/python; else echo python3; fi)

BIN      := verify_cube_par
SRC      := verify_cube_par.c

ROUNDS   ?= 32
NKEYS    ?= 5
SEED     ?= 42
CUBE     ?= 0 1 2 3

CONST_BIT    ?= 31
DIM31_ROUNDS ?= 32,48,64,72,80
TIMEOUT      ?= 1200

.PHONY: all build verify dim31 clean help

all: build

build: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

verify: $(BIN)
	./$(BIN) $(ROUNDS) $(NKEYS) $(SEED) $(CUBE)

dim31: $(BIN)
	$(PYTHON) verify_dim31.py --const-bit $(CONST_BIT) --nkeys $(NKEYS) --seed $(SEED) --rounds $(DIM31_ROUNDS) --timeout $(TIMEOUT)

clean:
	rm -f $(BIN)

help:
	@echo "Cube / integral verifier"
	@echo ""
	@echo "Targets:"
	@echo "  make build                     Build $(BIN)"
	@echo "  make verify CUBE='0 1 2 3'     Run empirical verification on one cube"
	@echo "  make dim31                     Run the optional dim-31 regression wrapper"
	@echo "  make clean                     Remove the verifier binary"
	@echo ""
	@echo "Variables:"
	@echo "  ROUNDS=$(ROUNDS) NKEYS=$(NKEYS) SEED=$(SEED)"
	@echo "  CUBE='$(CUBE)'"
	@echo "  CONST_BIT=$(CONST_BIT) DIM31_ROUNDS=$(DIM31_ROUNDS) TIMEOUT=$(TIMEOUT)"