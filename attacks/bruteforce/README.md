# KeeLoq CUDA Brute-Force Key Recovery

High performance GPU brute force attack on full 528 round KeeLoq.

Run the commands below from `attacks/bruteforce/`. Benchmark mode generates synthetic pairs from a known target key; fixed-bit experiments assume the specified secret bits are already known.

## Build

This folder requires the NVIDIA CUDA toolkit (`nvcc`).

```bash
make            # auto-detects GPU architecture
# or manually:
nvcc -O3 -std=c++17 --use_fast_math -arch=sm_120 -o keeloq_bf keeloq_bruteforce.cu
```

`sm_120` applies to the measured RTX PRO 6000 Blackwell Workstation Edition and RTX 50-series cards. For other devices, select the appropriate target from NVIDIA's [compute-capability list](https://developer.nvidia.com/cuda/gpus). With Make, override detection using, for example, `make GPU_ARCH=90` for an H100/H200. Rebuild with `make clean` or `make -B` after changing compilation flags.

## Quick Start

Benchmark the full-round bit-slice path:

```bash
make clean && make
./keeloq_bf --benchmark --fix-low 24
```

Timed benchmark variant:

```bash
make clean && make
/usr/bin/time -p ./keeloq_bf --benchmark --fix-low 24
```

The source defaults (`BLOCK_SIZE=192`, `MIN_BLOCKS_PER_SM=2`, `THREAD_INNER_BITS=8`) are the
tuned settings, so no flags are needed. Note that `MAXREG=` / `--maxrregcount` has **no effect**
on the bit-slice kernel: `__launch_bounds__` takes precedence over it. Change
`MIN_BLOCKS_PER_SM` in the source to control the register cap.

Run against explicit plaintext/ciphertext pairs:

```bash
./keeloq_bf --pt0 0xF741E2DB --ct0 0xE44F4CDF \
            --pt1 0x0CA69B92 --ct1 0xA6AC0EA2
```

This explicit-pair command searches the full key space and is not a quick test. The benchmark commands above use a smaller space.

## Usage

```
./keeloq_bf [options]

Options:
  --key KEY          Target key in hex (default: 0x5CEC6701B79FD949)
  --pt0 HEX          Plaintext 0
  --ct0 HEX          Ciphertext 0
  --pt1 HEX          Plaintext 1
  --ct1 HEX          Ciphertext 1
  --rounds N         Number of rounds (default: 528)
  --random-key       Use a random 64-bit target key for this run
  --fix-low N        Fix lowest N key bits to the target key value
  --fix-high N       Fix highest N key bits to the target key value
  --fix-mask HEX     Arbitrary bitmask of fixed positions
  --fix-value HEX    Value for fixed positions (default: from --key)
  --device N         CUDA device index (default: 0)
  --benchmark        Generate P/C pairs from --key and run
  -h, --help         Show help
```

### Examples

**Test run — 2⁴⁰ search space (24 bits fixed)**:
```bash
./keeloq_bf --benchmark --fix-low 24
```

**Random-key benchmark run (fresh random 64-bit key per launch)**:
```bash
./keeloq_bf --benchmark --random-key --fix-low 24
```

**Full 2⁶⁴ brute-force with known P/C pairs**:
```bash
./keeloq_bf --pt0 0xF741E2DB --ct0 0xE44F4CDF \
            --pt1 0x0CA69B92 --ct1 0xA6AC0EA2
```

**Reduced-round attack (e.g., 128 rounds)**:
```bash
./keeloq_bf --benchmark --rounds 128 --fix-low 24
```

## Strategy

The program filters candidates using **two plaintext–ciphertext pairs**. Two distinct pairs do not guarantee a unique 64-bit key: under an ideal-cipher heuristic, about one wrong key is expected to survive alongside the true key in the full key space. The program stops after a kernel chunk reports a match and prints the first stored matching key; it does not enumerate every match or accept a third pair. Verify that candidate against additional independent data before treating it as the original key.

The kernel uses **waterfall filtering**:

1. **Phase 1** tests every candidate key against pair 0. Almost all wrong keys fail here.
2. **Phase 2** tests only the rare survivors against pair 1. The same thread does this with early exit, so there is no extra storage cost and no second kernel launch.

This makes the effective cost about **1.0 encryption per candidate** instead of 2.0. In practice it almost halves the work compared with testing both pairs for every key.

### GPU Optimisations

- **Three kernel paths**: the bit-sliced path requires 528 rounds, contiguous free key bits, and at least five free bits. Other contiguous cases use the scalar fast path; noncontiguous `--fix-mask` patterns use the generic scalar path.
- **Bit-slice x32**: each thread carries 32 candidate keys as bit planes in `uint32_t` lanes, so one sequence of word-level Boolean instructions advances 32 keys through a round at once. With the inner loop, one thread covers $2^8 \times 32 = 8192$ consecutive keys.
- **Register resident state**: the 32 state planes and the 64 key planes stay in registers; the plaintext/ciphertext pairs are held in registers too.
- **NLF in 6 operations**: the KeeLoq NLF satisfies $\mathsf{NLF}(e,d,c,b,a) = \mathsf{NLF}(e,0,c \oplus d, b \oplus d, a \oplus d)$, so $d$ only complements the other inputs. That collapses the generic $(e,d)$ multiplexer tree to 3 XOR plus 3 three-input logic ops, evaluated lane-wise from the constant `0x3A5C742E` with no LUT in memory.
- **Index rotation**: the one-bit state shift is applied to the *subscript* rather than the data. With the round loop unrolled every subscript is a compile-time constant, so the shift costs no register moves.
- **Early filter at round 512**: by the NLFSR passthrough property the last 16 rounds only shift `state[31:16]` down into `ct[15:0]`, so `ct[15:0]` is already determined at round 512. Testing there rejects all 32 lanes with probability $(1-2^{-16})^{32} \approx 0.9995$ and skips the final 16 rounds.
- **Chunked launches**: multiple kernel launches cover the full space and report live progress between chunks.

### Benchmark Snapshot

Measured with the bit-slice contiguous kernel on an NVIDIA RTX PRO 6000 Blackwell Workstation
Edition (188 SMs, `sm_120`), built with `make` at the source defaults. Median of three consecutive
runs:

| Throughput | Keys tested | Kernel time | Notes |
|---:|---:|---:|---|
| 176.909 Gkeys/s | 412,316,860,416 | 2.331 s | `--fix-low 24`, key found at 37.5% of budget, host verification PASS |

Benchmark log summary:

- Search setup: `rounds=528`, `free bits=40`, `kernel=BIT-SLICE x32 (contiguous, 528r)`
- Grid: `192 threads/block (6 warps)`, `2^13 = 8192 keys/thread (32-way bit-slice)`
- Three runs: `177.527`, `176.909`, `176.284` Gkeys/s (0.7% spread)

This is about **2^37.36 keys/s**.

Environment for this measurement:

- GPU: `NVIDIA RTX PRO 6000 Blackwell Workstation Edition`, compute capability `12.0`, 97,887 MiB, 500 W board limit
- Driver: `590.48.01`
- CUDA toolkit: `Build cuda_12.8.r12.8/compiler.35583870_0`
- Kernel: `Linux 6.8.0-49-generic x86_64 GNU/Linux`

Practical note on speed variation:

- End-to-end throughput varies across runs and servers because runtime clock, power behaviour,
  driver version, and the position of the key hit all change.
- For fair comparison, run several trials with the same compile flags and report the median.
  Back-to-back runs on the same card drift downward by 1-2% as it heats up.

Recommended benchmark command:

```bash
make clean && make && ./keeloq_bf --benchmark --fix-low 24
```

Timed benchmark variant (times the benchmark stage only):

```bash
make clean && make && /usr/bin/time -p ./keeloq_bf --benchmark --fix-low 24
```

Capture the GPU/software environment alongside any reported number:

```bash
(
echo "date=$(date -Iseconds)"
echo "host=$(hostname)"
nvidia-smi --query-gpu=name,compute_cap,driver_version,memory.total,power.limit --format=csv,noheader
echo "cuda=$(nvcc --version | tail -n 1)"
echo "kernel=$(uname -srmo)"
) | tee bruteforce_gpu_config_compact.txt
```

## Full-Round KeeLoq Brute-Force Cost

Using the measured rate **R = 176.909e9 keys/s** from the benchmark above:

- Worst-case full search time (entire key space):
  - `T_worst = 2^64 / R`
  - **104,272,502 s = 28,965 h = 1,207 days = 3.30 years** (1 GPU)
- Expected time to hit the key (uniform random key position):
  - `T_avg = 2^63 / R`
  - **52,136,251 s = 14,482 h = 603 days = 1.65 years** (1 GPU)

### How Many GPUs For A Target Time?

Worst-case GPU count for target wall-clock time `H` hours:

- `N = ceil( 2^64 / (R * 3600 * H) )`

| Target time (worst-case) | GPUs needed |
|---|---:|
| 1 hour | 28,965 |
| 24 hours (1 day) | 1,207 |
| 168 hours (1 week) | 173 |
| 720 hours (30 days) | 41 |

Expected-time counts are about half of the table above. These are estimates for reaching the true key's position with sufficient verification data, not a guarantee that the program's first two-pair match is that key. The executable selects one GPU with `--device`; cluster figures assume an external partitioning scheme and do not describe built-in multi-GPU orchestration.

### Reference Times For Fixed GPU Counts

The reverse question: given a fixed number of GPUs, how long does a full search take?

| GPU count | Worst-case time | Expected time |
|---|---:|---:|
| 1 | 28,965 h = 3.30 years | 14,482 h = 1.65 years |
| 8 | 3,621 h = 151 days | 1,810 h = 75 days |
| 56 | 517 h = 21.5 days | 259 h = 10.8 days |
| 236 | 123 h = 5.1 days | 61 h = 2.6 days |
| 1,652 | 17.5 h | 8.8 h |

Important scope notes:

- These counts assume linear scaling across independent GPUs, which is reasonable here because
  candidate keys are tested independently with no communication between devices.
- They count **GPUs only**. They do not include host servers, CPUs, RAM, SSDs, networking, power
  delivery, cooling, racks, facility cost, or operational electricity.
- Acquisition cost is deliberately not tabulated, since it depends entirely on which card the rate
  is measured on and on current market pricing.

### Is There A Single Server With That Much Power?

- Not in the sense of a single conventional server holding 56, 236, or 1,652 cards. Those scales
  are **cluster scale**, not single-node scale.
- A practical deployment at those sizes would require many multi-GPU nodes.
- Using **8-GPU nodes** as a reference point, the table above corresponds to about **6 nodes** for
  the 30-day worst case, **22 nodes** for the 1-week worst case, and **151 nodes** for the 1-day
  worst case.
- Large GPU clusters do exist, but this README does **not** claim the existence of a public cluster
  built specifically from these counts.

## Output

- All diagnostic output goes to **stderr**.
- On success, the recovered key is printed to **stdout** in hex for scripting:
  ```
  0x5CEC6701B79FD949
  ```
- Exit code 0 = at least one two-pair matching candidate found, 1 = not found or error. A zero exit status alone does not prove unique recovery of the original key.
