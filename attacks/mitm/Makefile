CC      = cc
NVCC    = nvcc
CFLAGS  = -O3 -march=native -pthread -Wall -Wextra

# GPU settings — adjust -arch to your GPU:
#   sm_70 = Volta (V100), sm_80 = Ampere (A100/RTX 30xx)
#   sm_89 = Ada (RTX 40xx), sm_90 = Hopper (H100/H200)
#   sm_100 = Blackwell data center, sm_120 = Blackwell RTX 50xx
CUDA_ARCH ?= sm_89
GPU_STATS ?= 0

BASELINE_K0_BATCH ?= 64
BASELINE_UPJ_BATCH ?= 1
KP1515_K0_BATCH ?= 64
KP1515_OV_BATCH ?= 1
KP1515_FOUND_CHECK_INTERVAL ?= 1024
CP2013_K0_BATCH ?= 32
CP2013_OV_BATCH ?= 1

HOPPER_CUDA_ARCH ?= sm_90
# H100 measurement at 2^16 pairs: 64 x 1 is within 1% of 256 x 32 while
# reducing kp1515 allocation from 17,024.5 MB to 164.5 MB.
HOPPER_K0_BATCH ?= 64
HOPPER_OVERLAP_BATCH ?= 1
HOPPER_FOUND_CHECK_INTERVAL ?= 4096
HOPPER_BENCH_PAIRS_LOG2 ?= 14
HOPPER_BENCH_MAX_K0 ?= 32
HOPPER_BENCH_KEY ?= 000000000000001F

NVCCFLAGS = -O3 -arch=$(CUDA_ARCH)
HOPPER_NVCCFLAGS = -O3 -arch=$(HOPPER_CUDA_ARCH) -lineinfo

CPU_TARGETS = mitm mitm_generalized
GPU_TARGETS = mitm_gpu_baseline mitm_gpu_kp1515 mitm_gpu_cp2013 \
	mitm_gpu_baseline_hopper mitm_gpu_kp1515_hopper mitm_gpu_cp2013_hopper
LEGACY_GPU_TARGETS = mitm_gpu_baseline_h200 mitm_gpu_kp1515_h200 mitm_gpu_cp2013_h200

.PHONY: all build build-gpu cpu generalized gpu gpu-baseline gpu-kp1515 gpu-cp2013 \
	gpu-hopper benchmark-hopper gpu-h200 benchmark-h200 check-gpu clean clean-logs clean-all help

all: cpu

build: cpu

build-gpu: gpu

cpu: mitm

generalized: mitm_generalized

check-gpu:
	@if ! command -v $(NVCC) >/dev/null 2>&1; then \
		echo "[error] CUDA compiler '$(NVCC)' not found."; \
		echo "        Install CUDA or use CPU targets instead."; \
		exit 1; \
	fi
	@if ! command -v nvidia-smi >/dev/null 2>&1; then \
		echo "[warn] nvidia-smi not found; build may succeed but GPU execution may not work on this machine."; \
	fi

gpu: check-gpu mitm_gpu_kp1515

gpu-baseline: check-gpu mitm_gpu_baseline

gpu-kp1515: check-gpu mitm_gpu_kp1515

gpu-cp2013: check-gpu mitm_gpu_cp2013

gpu-hopper: check-gpu mitm_gpu_baseline_hopper mitm_gpu_kp1515_hopper mitm_gpu_cp2013_hopper

benchmark-hopper: gpu-hopper
	@echo "[benchmark] Hopper baseline 16/16/16"
	./mitm_gpu_baseline_hopper $(HOPPER_BENCH_KEY) --pairs-log2 $(HOPPER_BENCH_PAIRS_LOG2) --inject-slid-pair --max-k0 $(HOPPER_BENCH_MAX_K0)
	@echo "[benchmark] Hopper kp1515 15/15/14"
	./mitm_gpu_kp1515_hopper $(HOPPER_BENCH_KEY) --pairs-log2 $(HOPPER_BENCH_PAIRS_LOG2) --inject-slid-pair --max-k0 $(HOPPER_BENCH_MAX_K0)
	@echo "[benchmark] Hopper cp2013 20/13/17"
	./mitm_gpu_cp2013_hopper $(HOPPER_BENCH_KEY) --pairs-log2 $(HOPPER_BENCH_PAIRS_LOG2) --inject-slid-pair --max-k0 $(HOPPER_BENCH_MAX_K0)

# Backward-compatible aliases; H100 and H200 both use the Hopper sm_90 build.
gpu-h200: gpu-hopper

benchmark-h200: benchmark-hopper

mitm: mitm.c
	$(CC) $(CFLAGS) -o mitm mitm.c

mitm_generalized: mitm_generalized.c mitm_generalized.h
	$(CC) $(CFLAGS) -o mitm_generalized mitm_generalized.c

mitm_gpu_baseline: mitm_gpu_baseline.cu
	$(NVCC) $(NVCCFLAGS) -DK0_BATCH=$(BASELINE_K0_BATCH) -DUPJ_BATCH=$(BASELINE_UPJ_BATCH) -DENABLE_GPU_STATS=$(GPU_STATS) -o mitm_gpu_baseline mitm_gpu_baseline.cu

mitm_gpu_kp1515: mitm_gpu_kp1515.cu
	$(NVCC) $(NVCCFLAGS) -DK0_BATCH=$(KP1515_K0_BATCH) -DOV_BATCH=$(KP1515_OV_BATCH) -DFOUND_CHECK_INTERVAL=$(KP1515_FOUND_CHECK_INTERVAL) -DENABLE_GPU_STATS=$(GPU_STATS) -o mitm_gpu_kp1515 mitm_gpu_kp1515.cu

mitm_gpu_cp2013: mitm_gpu_cp2013.cu
	$(NVCC) $(NVCCFLAGS) -DK0_BATCH=$(CP2013_K0_BATCH) -DOV_BATCH=$(CP2013_OV_BATCH) -DENABLE_GPU_STATS=$(GPU_STATS) -o mitm_gpu_cp2013 mitm_gpu_cp2013.cu

mitm_gpu_baseline_hopper: mitm_gpu_baseline.cu
	$(NVCC) $(HOPPER_NVCCFLAGS) -DK0_BATCH=$(HOPPER_K0_BATCH) -DUPJ_BATCH=$(HOPPER_OVERLAP_BATCH) -DENABLE_GPU_STATS=$(GPU_STATS) -o $@ $<

mitm_gpu_kp1515_hopper: mitm_gpu_kp1515.cu
	$(NVCC) $(HOPPER_NVCCFLAGS) -DK0_BATCH=$(HOPPER_K0_BATCH) -DOV_BATCH=$(HOPPER_OVERLAP_BATCH) -DFOUND_CHECK_INTERVAL=$(HOPPER_FOUND_CHECK_INTERVAL) -DENABLE_GPU_STATS=$(GPU_STATS) -o $@ $<

mitm_gpu_cp2013_hopper: mitm_gpu_cp2013.cu
	$(NVCC) $(HOPPER_NVCCFLAGS) -DK0_BATCH=$(HOPPER_K0_BATCH) -DOV_BATCH=$(HOPPER_OVERLAP_BATCH) -DENABLE_GPU_STATS=$(GPU_STATS) -o $@ $<

clean:
	rm -f $(CPU_TARGETS) $(GPU_TARGETS) $(LEGACY_GPU_TARGETS)

clean-logs:
	rm -f *.log phase5_*.log cpu_cmp_*.log cp_*.log kp_*.log real_*.log

clean-all: clean clean-logs

help:
	@echo "KeeLoq Slide + MitM"
	@echo ""
	@echo "Build targets:"
	@echo "  make build              build default CPU target (mitm)"
	@echo "  make generalized        build CPU generalized reference"
	@echo "  make gpu                build recommended GPU profile (15/15/14)"
	@echo "  make gpu-baseline       build fixed baseline GPU profile (16/16/16)"
	@echo "  make gpu-kp1515         build recommended GPU profile (15/15/14)"
	@echo "  make gpu-cp2013         build chosen-profile GPU candidate (20/13/17)"
	@echo "  make gpu-hopper         build all GPU profiles for H100/H200"
	@echo "  make benchmark-hopper   run bounded H100/H200 recovery benchmarks"
	@echo "  make gpu-h200           compatibility alias for gpu-hopper"
	@echo ""
	@echo "Key options:"
	@echo "  CUDA_ARCH=sm_90         target GPU architecture"
	@echo "  KP1515_K0_BATCH=64      kp1515 low-key batch"
	@echo "  KP1515_OV_BATCH=1       kp1515 overlap batch"
	@echo "  GPU_STATS=0             disable hot-path GPU counters (set 1 to enable)"
	@echo "  HOPPER_K0_BATCH=64      H100/H200 low-key batch"
	@echo "  HOPPER_OVERLAP_BATCH=1  H100/H200 overlap batch"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean              remove binaries"
	@echo "  make clean-logs         remove generated run logs"
	@echo "  make clean-all          remove binaries and logs"
