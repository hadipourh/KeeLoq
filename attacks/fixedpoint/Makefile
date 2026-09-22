# ====================================================================
#  KeeLoq Fixed-Point Attack — Full Pipeline
# ====================================================================
#
#  Phase 1 (C):   Scan 2^32 plaintexts, filter, peel → k[0..15]
#  Phase 2:      Directed-pair SAT + exact singleton recovery → k[16..63]
#
#  Usage:
#    make            # build + run full attack (default key)
#    make random     # full attack with a random key
#    make benchmark  # run multi-key benchmark (CSV/TXT output)
#    make build      # compile CPU Phase 1 + singleton helper
#    make phase1     # run Phase 1 (scan, ~20 min)
#    make phase2     # run Phase 2 recovery
#    make test       # quick unit tests (peel, bench, e16)
#    make clean      # remove binaries and data
#
#  Options (override on command line):
#    KEY=0x...       # target key      (default: 0x5CEC6701B79FD949)
#    THREADS=N       # default thread setting for both phases (default: 10)
#    PHASE1_THREADS=N # Phase 1 threads / GPU threads-per-block
#    PHASE2_THREADS=N # Phase 2 worker count
#    SOLVER=...      # SAT solver      (default: cadical)
#    BENCH_KEYS=N    # benchmark trials (default: 100)
#    BENCH_SEED=N    # benchmark RNG seed (default: 42)
# ====================================================================

CC       := cc
CFLAGS   := -O3 -march=native -Wall
LDFLAGS  := -lpthread
NVCC     ?= nvcc
CUDAFLAGS:= -O3 --use_fast_math
UNAME_S  := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
SINGLETON_HELPER := singleton_helper.dylib
SINGLETON_HELPER_LDFLAGS := -dynamiclib
else
SINGLETON_HELPER := singleton_helper.so
SINGLETON_HELPER_LDFLAGS := -shared
endif

# Python: use venv/bin/python if it exists, otherwise python3 on PATH
VENV     ?= venv
PYTHON   := $(shell if [ -x $(VENV)/bin/python ]; then echo $(VENV)/bin/python; else echo python3; fi)

KEY      ?= 0x5CEC6701B79FD949
THREADS  ?= 10
PHASE1_THREADS ?= $(THREADS)
PHASE2_THREADS ?= $(THREADS)
SOLVER   ?= cadical
BENCH_KEYS ?= 100
BENCH_SEED ?= 42
BENCH_PHASE1_ONLY ?= 0
BENCH_PHASE1_BACKEND ?= cpu
BENCH_PHASE1_THREADS ?= $(THREADS)
BENCH_PHASE2_THREADS ?= $(THREADS)
BENCH_SKIP_PHASE2_IF_ABSENT ?= 0
PHASE1_BACKEND ?= cpu

# Binaries
BIN_MT   := fixedpoint_mt
BIN_GPU  := fixedpoint_gpu

# Outputs
DATA     := fixedpoint_data.txt

# ====================================================================
#  Default: full pipeline
# ====================================================================

.PHONY: all build build-gpu build-helper build-singleton-gpu phase1 phase1-cpu phase1-gpu phase2 attack random benchmark test clean help check-gpu

all: attack

attack:
	@$(MAKE) phase1 \
		KEY=$(KEY) \
		THREADS=$(THREADS) \
		PHASE1_THREADS=$(PHASE1_THREADS) \
		PHASE2_THREADS=$(PHASE2_THREADS) \
		PHASE1_BACKEND=$(PHASE1_BACKEND)
	@$(MAKE) phase2 \
		KEY=$(KEY) \
		THREADS=$(THREADS) \
		PHASE1_THREADS=$(PHASE1_THREADS) \
		PHASE2_THREADS=$(PHASE2_THREADS) \
		PHASE1_BACKEND=$(PHASE1_BACKEND) \
		SOLVER=$(SOLVER)

# Run full attack with KEY if provided; otherwise generate a random 64-bit key
random:
	$(eval RAND_KEY := $(if $(filter 0x%,$(KEY)),$(KEY),$(shell $(PYTHON) -c "import random,time; random.seed(int(time.time())); print(f'0x{random.getrandbits(64):016X}')")))
	@echo ""
	@echo "════════════════════════════════════════════════════════════"
	@echo "  Random/Explicit Key Attack"
	@echo "  Key: $(RAND_KEY)"
	@echo "════════════════════════════════════════════════════════════"
	$(MAKE) clean
	$(MAKE) attack \
		KEY=$(RAND_KEY) \
		THREADS=$(THREADS) \
		PHASE1_THREADS=$(PHASE1_THREADS) \
		PHASE2_THREADS=$(PHASE2_THREADS) \
		PHASE1_BACKEND=$(PHASE1_BACKEND) \
		SOLVER=$(SOLVER)

benchmark:
	@echo ""
	@echo "════════════════════════════════════════════════════════════"
	@echo "  Fixed-Point Benchmark"
	@echo "  Keys: $(BENCH_KEYS), P1 threads: $(BENCH_PHASE1_THREADS), P2 threads: $(BENCH_PHASE2_THREADS), Solver: $(SOLVER)"
	@echo "════════════════════════════════════════════════════════════"
	@echo ""
	$(PYTHON) benchmark.py --num-keys $(BENCH_KEYS) --threads $(THREADS) --phase1-threads $(BENCH_PHASE1_THREADS) --phase2-threads $(BENCH_PHASE2_THREADS) --solver $(SOLVER) --seed $(BENCH_SEED) --phase1-backend $(BENCH_PHASE1_BACKEND) $(if $(filter 1 true yes,$(BENCH_PHASE1_ONLY)),--phase1-only,) $(if $(filter 1 true yes,$(BENCH_SKIP_PHASE2_IF_ABSENT)),--skip-phase2-if-absent,)
	@echo ""
	@echo "Benchmark outputs: fixedpoint_benchmark.csv, fixedpoint_benchmark.txt"

# ====================================================================
#  Build targets
# ====================================================================

build: $(BIN_MT) $(SINGLETON_HELPER)

build-gpu: $(BIN_GPU)

build-helper: $(SINGLETON_HELPER)

build-singleton-gpu: singleton_gpu_prefilter

$(BIN_MT): fixedpoint_mt.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

$(BIN_GPU): fixedpoint_gpu.cu
	$(NVCC) $(CUDAFLAGS) -o $@ $<

$(SINGLETON_HELPER): singleton_helper.c keeloq.c keeloq.h
	$(CC) $(CFLAGS) -fPIC $(SINGLETON_HELPER_LDFLAGS) -o $@ singleton_helper.c keeloq.c

singleton_gpu_prefilter: singleton_gpu_prefilter.cu
	$(NVCC) $(CUDAFLAGS) -o $@ $<


# ====================================================================
#  Phase 1: Scan + Filter + Peel + Majority Vote
# ====================================================================

check-gpu:
	@if ! command -v $(NVCC) >/dev/null 2>&1; then \
		echo "[error] CUDA compiler '$(NVCC)' not found."; \
		echo "        Install CUDA or run with PHASE1_BACKEND=cpu."; \
		exit 1; \
	fi
	@if ! command -v nvidia-smi >/dev/null 2>&1; then \
		echo "[error] NVIDIA runtime not detected ('nvidia-smi' missing)."; \
		echo "        This system does not appear to expose an NVIDIA GPU."; \
		echo "        Use PHASE1_BACKEND=cpu or run on a GPU-enabled machine."; \
		exit 1; \
	fi
	@if ! nvidia-smi -L >/dev/null 2>&1; then \
		echo "[error] No usable NVIDIA GPU detected."; \
		nvidia-smi || true; \
		echo "        Use PHASE1_BACKEND=cpu or fix the GPU driver/runtime."; \
		exit 1; \
	fi

phase1:
	@if [ "$(PHASE1_BACKEND)" != "cpu" ] && [ "$(PHASE1_BACKEND)" != "gpu" ]; then \
		echo "[error] Invalid PHASE1_BACKEND='$(PHASE1_BACKEND)'. Use cpu or gpu."; \
		exit 2; \
	fi
	@echo "[phase1] backend=$(PHASE1_BACKEND) phase1_threads=$(PHASE1_THREADS)"
	@if [ "$(PHASE1_BACKEND)" = "gpu" ]; then \
		$(MAKE) phase1-gpu KEY=$(KEY) THREADS=$(THREADS) PHASE1_THREADS=$(PHASE1_THREADS); \
	else \
		$(MAKE) phase1-cpu KEY=$(KEY) THREADS=$(THREADS) PHASE1_THREADS=$(PHASE1_THREADS); \
	fi

phase1-cpu:
	@echo "[build] Recompiling $(BIN_MT) for current machine..."
	$(CC) $(CFLAGS) -o $(BIN_MT) fixedpoint_mt.c $(LDFLAGS)
	@echo ""
	@echo "════════════════════════════════════════════════════════════"
	@echo "  Phase 1: Fixed-Point Scan ($(PHASE1_THREADS) threads) [CPU]"
	@echo "════════════════════════════════════════════════════════════"
	@echo ""
	./$(BIN_MT) $(PHASE1_THREADS) $(KEY)

phase1-gpu: check-gpu
	@echo "[build] Compiling $(BIN_GPU) with CUDA..."
	$(NVCC) $(CUDAFLAGS) -o $(BIN_GPU) fixedpoint_gpu.cu
	@echo ""
	@echo "════════════════════════════════════════════════════════════"
	@echo "  Phase 1: Fixed-Point Scan (CUDA GPU)"
	@echo "  Threads/block: $(PHASE1_THREADS)"
	@echo "════════════════════════════════════════════════════════════"
	@echo ""
	./$(BIN_GPU) $(PHASE1_THREADS) $(KEY)

# ====================================================================
#  Phase 2: Recovery of k[16..63]
# ====================================================================

phase2: $(DATA)
	@echo ""
	@echo "════════════════════════════════════════════════════════════"
	@echo "  Phase 2: Key Recovery"
	@echo "  CPU workers: $(PHASE2_THREADS)"
	@echo "════════════════════════════════════════════════════════════"
	@echo ""
	$(PYTHON) fixedpoint_sat.py --key $(KEY) --solver $(SOLVER) --workers $(PHASE2_THREADS)

$(DATA):
	@if [ ! -f $(DATA) ]; then \
		echo "fixedpoint_data.txt not found — running Phase 1 first..."; \
		$(MAKE) phase1 KEY=$(KEY) THREADS=$(THREADS) PHASE1_THREADS=$(PHASE1_THREADS) PHASE1_BACKEND=$(PHASE1_BACKEND); \
	fi

# ====================================================================
#  Tests
# ====================================================================

test:
	@echo "No unit tests configured (test files removed)."

# ====================================================================
#  Clean
# ====================================================================

clean:
	rm -f $(BIN_MT) $(BIN_GPU) $(SINGLETON_HELPER)
	rm -f singleton_gpu_prefilter
	rm -f $(DATA)
	rm -f survivors.csv fixedpoint_benchmark.csv fixedpoint_benchmark.txt
	rm -rf __pycache__
	rm -f *.o

# ====================================================================
#  Help
# ====================================================================

help:
	@echo "KeeLoq Fixed-Point Attack"
	@echo ""
	@echo "  make              build + run full attack (Phase 1 + Phase 2)"
	@echo "  make random       full attack with a random key"
	@echo "                    (or with explicit KEY=0x... if provided)"
	@echo "  make benchmark    run multi-key benchmark (writes CSV/TXT)"
	@echo "  make build        compile CPU Phase 1 binary + singleton helper"
	@echo "  make build-gpu    compile GPU Phase 1 binary (CUDA)"
	@echo "  make phase1       run Phase 1 scan (~20 min with 10 threads)"
	@echo "  make phase2       run Phase 2 recovery"
	@echo "  make test         run unit tests (peel, bench, e16)"
	@echo "  make clean        remove binaries and output files"
	@echo ""
	@echo "Options:"
	@echo "  KEY=0x...         target key (default: 0x5CEC6701B79FD949)"
	@echo "  THREADS=N         default thread setting for both phases (default: 10)"
	@echo "  PHASE1_THREADS=N  Phase 1 CPU threads / GPU threads-per-block"
	@echo "  PHASE2_THREADS=N  Phase 2 worker count"
	@echo "  SOLVER=NAME       SAT solver: cryptominisat|cadical (default: cadical)"
	@echo "  BENCH_KEYS=N      benchmark trial count (default: 100)"
	@echo "  BENCH_SEED=N      benchmark RNG seed (default: 42)"
	@echo "  BENCH_PHASE1_ONLY=1  benchmark Phase 1 only (skip SAT)"
	@echo "  BENCH_PHASE1_BACKEND=cpu|gpu benchmark Phase 1 backend (default: cpu)"
	@echo "  BENCH_PHASE1_THREADS=N benchmark Phase 1 CPU threads / GPU threads-per-block"
	@echo "  BENCH_PHASE2_THREADS=N benchmark Phase 2 worker count"
	@echo "  BENCH_SKIP_PHASE2_IF_ABSENT=1 benchmark-only oracle skip when votes_true=0"
	@echo "  PHASE1_BACKEND=cpu|gpu select Phase 1 backend for make attack/phase1"
	@echo ""
	@echo "Note: 'make attack random' runs BOTH targets."
	@echo "      Use only one target per invocation:"
	@echo "        make attack ...   OR   make random ..."
