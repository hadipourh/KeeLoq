CC         := gcc
PYTHON     := python3
TARGET     := algebraic_polygen

BUILD      ?= debug
ROUNDS     ?= 64
PAIRS      ?= 1
SOLVER     ?= cryptominisat

ifeq ($(BUILD),release)
    CFLAGS := -O3 -Wall
else
    CFLAGS := -g -Wall
endif

OBJS := polygen_cli.o polygen.o keeloq.o

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

polygen_cli.o: polygen_cli.c polygen.h keeloq.h
	$(CC) $(CFLAGS) -c polygen_cli.c

polygen.o: polygen.c polygen.h
	$(CC) $(CFLAGS) -c polygen.c

keeloq.o: keeloq.c keeloq.h
	$(CC) $(CFLAGS) -c keeloq.c

sat:
	$(PYTHON) sat_solver.py --rounds $(ROUNDS) --pairs $(PAIRS) --solver $(SOLVER)

groebner:
	$(PYTHON) groebner_solver.py --rounds $(ROUNDS) --pairs $(PAIRS)

polygen: $(TARGET)
	./$(TARGET) polygen

polygen-sym: $(TARGET)
	./$(TARGET) polygen-sym

slide528: $(TARGET)
	./$(TARGET) slide528

slide528-sym: $(TARGET)
	./$(TARGET) slide528-sym

# CPU SAT benchmarking (no GPU backend)
BENCH_ROUNDS   ?= 120
BENCH_PAIRS    ?= 1
BENCH_WORKERS  ?= 8
BENCH_MAX_ENUM ?= 2000

benchmark-cpu:
	@echo ""
	@echo "════════════════════════════════════════════════════════════"
	@echo "  SAT CPU benchmark (rounds=$(BENCH_ROUNDS), pairs=$(BENCH_PAIRS), workers=$(BENCH_WORKERS))"
	@echo "════════════════════════════════════════════════════════════"
	@echo ""
	@echo "[1] baseline: single-worker SAT"
	$(PYTHON) sat_solver.py --rounds $(BENCH_ROUNDS) --pairs $(BENCH_PAIRS) \
		--solver cadical --max-enum $(BENCH_MAX_ENUM) --enum-workers 1
	@echo ""
	@echo "[2] parallel SAT enumeration: $(BENCH_WORKERS) workers"
	$(PYTHON) sat_solver.py --rounds $(BENCH_ROUNDS) --pairs $(BENCH_PAIRS) \
		--solver cadical --max-enum $(BENCH_MAX_ENUM) --enum-workers $(BENCH_WORKERS)
	@echo ""
	@echo "[3] optional backbone + pairwise-affine diagnostics"
	$(PYTHON) sat_solver.py --rounds $(BENCH_ROUNDS) --pairs $(BENCH_PAIRS) \
		--solver cadical --max-enum 0 --backbone --pairwise-affine \
		--pairwise-workers $(BENCH_WORKERS)
	@echo ""
	@echo "Done. This benchmark uses CPU-only SAT modes."

# ── Python / misc ─────────────────────────────────────────────────────────────

setup-python:
	$(PYTHON) -m pip install -r requirements.txt

clean:
	rm -f $(OBJS) $(TARGET) mqkeeloq.txt mqkeeloq_symbolic.txt
	rm -rf __pycache__
	find . -name "*.pyc" -delete

.PHONY: all sat groebner polygen polygen-sym slide528 slide528-sym \
	benchmark-cpu setup-python clean
