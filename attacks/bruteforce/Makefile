# Detect GPU architecture if possible, fall back to a reasonable default
NVCC       ?= nvcc
NVCC_FLAGS ?= -O3 --use_fast_math -std=c++17

# Try to detect the GPU architecture of the first visible device.
# Falls back to sm_70 (Volta) which covers V100 and everything newer.
GPU_ARCH := $(shell nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.')
ifeq ($(GPU_ARCH),)
  GPU_ARCH_FLAG = -arch=sm_70
else
  GPU_ARCH_FLAG = -arch=sm_$(GPU_ARCH)
endif

# Optional tuning knobs (override on command line):
#   make BLOCK_SIZE=128 INNER_BITS=10 MAXREG=128
# MAXREG: per-thread register cap.  IGNORED for the bit-slice kernel --
#         __launch_bounds__ overrides it; use MIN_BLOCKS_PER_SM in the source.
#   For the bit-slice kernel, 128 is a good starting point.
#   Leave unset to let ptxas decide (usually best for the scalar kernel).
BLOCK_SIZE    ?=
INNER_BITS    ?=
MAXREG        ?=

TUNE_FLAGS =
ifneq ($(BLOCK_SIZE),)
  TUNE_FLAGS += -DBLOCK_SIZE=$(BLOCK_SIZE)
endif
ifneq ($(INNER_BITS),)
  TUNE_FLAGS += -DTHREAD_INNER_BITS=$(INNER_BITS)
endif
ifneq ($(MAXREG),)
  TUNE_FLAGS += --maxrregcount=$(MAXREG)
endif

TARGET = keeloq_bf
SRC    = keeloq_bruteforce.cu

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(NVCC) $(NVCC_FLAGS) $(TUNE_FLAGS) $(GPU_ARCH_FLAG) -o $@ $<

clean:
	rm -f $(TARGET)
