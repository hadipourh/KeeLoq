# Algebraic Attacks on KeeLoq

This directory contains three algebraic tools for KeeLoq: a SAT solver, a Groebner basis solver, and a local equation generator.

The scope matters. The code can build algebraic instances for many round counts, including exploratory 512 round and 528 round SAT cases. That does not mean this folder gives a practical direct full round key recovery attack. For generic plaintext ciphertext pairs, direct algebraic recovery on all 528 rounds is not practical with this workflow. In practice, this folder is most useful for reduced round experiments and for studying `--slide528`, which turns a full round slid pair into two 64 round constraints.

## Installation

Install the full local Python environment:

```bash
cd attacks/algebraic
python3 -m pip install -r requirements.txt
```

Dependencies in `requirements.txt`:

- `python-sat`
- `pycryptosat`
- `passagemath-standard`

Notes:

- `python-sat` is enough for the PySAT backends `cadical`, `glucose`, and `minisat`.
- `pycryptosat` is only needed for the `cryptominisat` backend.
- `passagemath-standard` is only needed for the Groebner workflow.
- If `pycryptosat` is unavailable on your platform, use `--solver cadical` for SAT experiments.

## Quick Start

Basic reduced-round SAT solve:

```bash
cd attacks/algebraic
python sat_solver.py --rounds 64 --pairs 1 --solver cadical
```

Controlled SAT benchmark with correct fixed bits:

```bash
python sat_solver.py --rounds 64 --pairs 2 --solver cadical --fixed-bits 16 --fixed-source correct
```

Basic Groebner experiment:

```bash
python groebner_solver.py --rounds 32 --pairs 2
```

Build the local equation generator:

```bash
make
make polygen
```

## Contents

- `sat_solver.py`: SAT-based reduced-round key recovery and enumeration
- `groebner_solver.py`: Groebner-basis reduced-round key recovery
- `polygen.c`, `polygen.h`: C equation generator
- `polygen_cli.c`: standalone CLI for equation generation
- `keeloq.c`, `keeloq.h`: local cipher copy used by the equation-generator build
- `Makefile`: local build and benchmark helpers
- `requirements.txt`: Python dependencies for the SAT and Groebner workflows

## What Each Tool Is For

### SAT solver

The SAT workflow models KeeLoq round relations as CNF and XOR constraints over GF(2). It is the main tool in this directory.

Capabilities:

- reduced-round SAT solving for arbitrary round counts
- fixed known key bits via `--fixed-bits` or `--fixed-indices`
- guessed-variable injection via `--guess-vars` or `--guess-vars-file`
- holdout verification on extra pairs, so a candidate must generalize beyond the solving pair set
- blocking-clause enumeration of additional solutions when the first model is spurious
- CPU-only parallel enumeration via `--enum-workers`
- optional backbone probing via `--backbone`
- optional pairwise affine relation mining via `--pairwise-affine`
- optional `--slide528` mode for the slid-pair decomposition into two 64-round components

### Groebner solver

The Groebner workflow models KeeLoq as multivariate polynomial equations over GF(2) and solves them with passagemath. Use it for smaller reduced round experiments than the SAT workflow.

### Equation generator

The local C generator writes the algebraic system in text form, either concrete or symbolic.

## Scope and Round Counts

Recommended use:

- `sat_solver.py`: reduced-round experiments, typically around 64 to 160 rounds depending on how much side information is provided
- `groebner_solver.py`: smaller reduced-round systems, with 32 rounds as the default starting point
- `--slide528`: study of a full-round slid pair through two 64-round algebraic components

What is possible, but should be read with care:

- You can ask the SAT frontend to build 512 round or 528 round direct instances.
- Those runs are useful for stress tests, clause count studies, and experiments with guessed variables or fixed bits.
- They are not evidence of a practical generic direct algebraic attack on full KeeLoq.

## SAT Workflow

The usual SAT workflow is:

1. Build a reduced-round SAT instance from `n` plaintext-ciphertext pairs.
2. Solve for one candidate key.
3. Verify that candidate on extra holdout pairs.
4. If it fails holdout, enumerate more SAT solutions.
5. Optionally add side information with fixed bits, guessed variables, backbone probing, or pairwise affine mining.

### Common SAT Commands

Basic reduced-round solve:

```bash
cd attacks/algebraic
python sat_solver.py --rounds 64 --pairs 1 --solver cadical
```

Easier reduced-round instance with two pairs:

```bash
python sat_solver.py --rounds 64 --pairs 2 --solver cadical
```

Inject correct fixed bits for a controlled benchmark:

```bash
python sat_solver.py --rounds 64 --pairs 2 --solver cadical --fixed-bits 16 --fixed-source correct
```

Use guessed intermediate variables from the true target instance:

```bash
python sat_solver.py --rounds 160 --pairs 2 --solver cadical --guess-vars "b_0_67 b_1_67 b_0_140 b_1_140" --guess-source correct
```

Load guessed variables from a file:

```bash
python sat_solver.py --rounds 160 --pairs 2 --solver cadical --guess-vars-file guesses.txt --guess-source correct
```

Build an experimental high-round direct SAT instance with boundary bits fixed:

```bash
python sat_solver.py --rounds 528 --pairs 1 --solver cadical --fixed-indices 0-15,48-63 --fixed-source correct --max-enum 0
```

That last command is an exploratory large-round run, not a recommended or practical full-round attack configuration.

### Important Options

- `--rounds`, `-r`: number of rounds to model
- `--pairs`, `-n`: number of plaintext-ciphertext pairs used in the SAT instance
- `--solver`, `-s`: `cryptominisat`, `cadical`, `glucose`, or `minisat`
- `--key`, `-k`: 64-bit target key used to generate the synthetic instance
- `--fixed-bits`: fix the lowest `N` key bits `k[0..N-1]`
- `--fixed-indices`: fix exactly these key bit positions, for example `0-15,48-63`; overrides `--fixed-bits`
- `--fixed-source`: choose fixed-bit values from `unknown`, `correct`, `random`, or `user`
- `--fixed-value`: 64-bit value used when `--fixed-source=user`
- `--guess-vars`: guessed variables on the CLI; supports `k_i`, `L_p_r`, `a_p_r`, `b_p_r`, plus optional `=0` or `=1`
- `--guess-vars-file`: load guessed variables from a text file
- `--guess-source`: assign bare guessed-variable names using `unknown`, `correct`, or `random`
- `--verify-extra-pairs`: number of extra holdout pairs used only after the solver returns a candidate
- `--max-enum`: maximum number of extra SAT solutions to enumerate after a failed holdout check; `0` disables enumeration
- `--enum-workers`, `-w`: number of CPU workers for partitioned parallel enumeration
- `--backbone`: probe whether any key bits are individually forced by the SAT instance before enumeration
- `--pairwise-affine`: probe whether any exact relations of the form `k_i XOR k_j = c` hold across all solutions
- `--pairwise-workers`: number of worker processes for pairwise-affine mining
- `--slide528`: derive the slid-pair decomposition into two 64-round constraints instead of a direct monolithic reduced-round instance

### Fixed Bits and Guessed Variables

Two different mechanisms reduce the search space:

- fixed key bits: force selected key positions to known or chosen values
- guessed variables: inject values for selected key bits or intermediate variables

Bare guessed-variable names such as `b_0_67` or `L_1_120` follow `--guess-source`:

- `--guess-source correct`: use the true value for the generated target instance
- `--guess-source random`: use random bits
- `--guess-source unknown`: keep the variable selected but leave it unfixed

Explicit assignments override `--guess-source`, for example:

- `k_19=1`
- `a_0_67=0`

`a_p_r` and `b_p_r` are accepted even though they are not materialized as standalone SAT variables; the solver translates them into equivalent constraints on the underlying state bits.

### Verification and Underconstrained Instances

One plaintext ciphertext pair does not uniquely determine a 64 bit KeeLoq key. So the solver separates two notions:

- a key that satisfies the solving pair set
- a key that also survives verification on independent holdout pairs

Heuristically, with `n` pairs and `b` fixed key bits, the residual solution count is about $2^{64 - b - 32n}$.

Example:

- `--pairs 1 --fixed-bits 32` gives a heuristic residual space near $2^0 = 1$ on average.
- That does not guarantee uniqueness for a concrete instance. Collisions and spurious first solutions can occur.

When the first SAT solution fails holdout verification, the solver adds a blocking clause and continues enumerating, up to `--max-enum` additional models.

### Parallel Enumeration

`--enum-workers N` parallelizes only the enumeration stage, and it is CPU only.

Mechanism:

- the solver picks `ceil(log2(N))` unfixed key bits
- each worker receives one assignment pattern for those bits
- each worker builds its own SAT solver on the same CNF and enumerates only inside its partition
- workers stop early when one of them finds a holdout verified key

This improves throughput on ambiguous instances, but it does not make an underconstrained problem uniquely determined.

### Backbone and Pairwise-Affine Modes

These modes try to extract structure from the SAT instance before brute force style enumeration.

- `--backbone` checks whether any single key bits are forced in all satisfying assignments.
- `--pairwise-affine` checks whether any exact relations `k_i XOR k_j = c` hold across all satisfying assignments.

Use them as diagnostics and as possible search space reducers. They are exact analyses of the SAT instance, not heuristics, but in weakly constrained regimes they may return no useful structure.

Example:

```bash
python sat_solver.py --rounds 120 --pairs 1 --solver cadical --max-enum 0 --backbone --pairwise-affine --pairwise-workers 8
```

### More SAT Examples

Fix the lowest 16 bits to the true target-key values:

```bash
python sat_solver.py --rounds 64 --pairs 2 --solver cadical --fixed-bits 16 --fixed-source correct
```

Use a mixed guess basis directly on the CLI:

```bash
python sat_solver.py --rounds 160 --pairs 2 --solver cadical --fixed-indices 0-15 --fixed-source correct --guess-vars "b_0_67 b_1_67 L_0_120" --guess-source correct
```

Force an explicit manual assignment:

```bash
python sat_solver.py --rounds 64 --pairs 1 --solver cadical --guess-vars "k_0=1 a_0_32=0 b_0_32"
```

Keep a guessed-variable set selected but unfixed:

```bash
python sat_solver.py --rounds 160 --pairs 2 --solver cadical --guess-vars-file guesses.txt --guess-source unknown
```

Assign random values to a guessed-variable set:

```bash
python sat_solver.py --rounds 160 --pairs 2 --solver cadical --guess-vars-file guesses.txt --guess-source random
```

Test a user-supplied fixed-bit value:

```bash
python sat_solver.py --rounds 64 --pairs 2 --solver cadical --fixed-bits 24 --fixed-source user --fixed-value 0x1234567890ABCDEF
```

Add extra holdout checks to an underconstrained run:

```bash
python sat_solver.py --rounds 128 --pairs 1 --solver cadical --fixed-bits 32 --fixed-source random --verify-extra-pairs 4
```

Disable enumeration and stop after the first candidate:

```bash
python sat_solver.py --rounds 64 --pairs 1 --solver cadical --max-enum 0
```

Enumerate up to 50 more solutions after a failed holdout check:

```bash
python sat_solver.py --rounds 64 --pairs 1 --solver cadical --fixed-bits 16 --fixed-source correct --max-enum 50
```

Parallel enumeration with 8 CPU workers:

```bash
python sat_solver.py --rounds 120 --pairs 1 --solver cadical --fixed-bits 16 --fixed-source correct --max-enum 2000 --enum-workers 8
```

Fix all 64 bits to a user-supplied value:

```bash
python sat_solver.py --rounds 64 --pairs 2 --solver cadical --fixed-bits 64 --fixed-source user --fixed-value 0x5CEC6701B79FD949
```

## Groebner Workflow

Basic usage:

```bash
cd attacks/algebraic
python groebner_solver.py --rounds 32 --pairs 2
python groebner_solver.py --rounds 32 --pairs 2 --use-polygen
```

Useful options:

- `--rounds`, `-r`: number of rounds to model
- `--pairs`, `-n`: number of plaintext-ciphertext pairs
- `--use-polygen`, `-p`: use the polygen-style equation format with auxiliary variables
- `--slide528`: derive two 64-round constraints from the full cipher using the slid-pair decomposition

The Groebner workflow is mainly for smaller reduced round systems. Treat `--slide528` the same way as in the SAT solver: it is a decomposition into 64 round components, not a direct 528 round Groebner attack.

## Equation Generator

Build the local equation generator:

```bash
cd attacks/algebraic
make
```

Generate equations:

```bash
make polygen
make polygen-sym
make slide528
make slide528-sym
```

Generated files:

- `mqkeeloq.txt`
- `mqkeeloq_symbolic.txt`

## Makefile Shortcuts

```bash
make               # build the standalone equation generator
make sat           # run SAT solver with defaults
make groebner      # run Groebner solver with defaults
make polygen       # generate concrete reduced-round equations
make polygen-sym   # generate symbolic reduced-round equations
make slide528      # generate concrete slide528 equations
make slide528-sym  # generate symbolic slide528 equations
make setup-python  # install Python dependencies from requirements.txt
make benchmark-cpu # benchmark CPU-only SAT modes
make clean         # remove local build artifacts
```

## CPU-Only SAT Benchmark

The SAT workflow in this directory is CPU only. To benchmark parallel SAT enumeration:

```bash
cd attacks/algebraic
make benchmark-cpu BENCH_ROUNDS=120 BENCH_PAIRS=1 BENCH_WORKERS=8 BENCH_MAX_ENUM=2000
```

Notes:

- the benchmark compares single worker enumeration and parallel CPU enumeration
- no GPU backend is used for SAT enumeration
- the optional third probe prints backbone and pairwise affine diagnostics

### Measured macOS Benchmarks (Basic Experiments)

Timed with `/usr/bin/time -p`.

System information:

- Product: macOS 26.3.1 (Build 25D2128)
- Kernel: Darwin 25.3.0 (`arm64`, `xnu-12377.91.3~2`, `RELEASE_ARM64_T8132`)
- CPU: Apple M4
- Logical CPU cores: 10
- Memory: 25769803776 bytes (24 GiB)

Observed runs:

| Case | Command | First SAT solve | Enumeration mode | End-to-end (`time -p`) | Outcome |
|------|---------|-----------------|------------------|------------------------|---------|
| Easy baseline (64r, 2 pairs) | `python sat_solver.py --rounds 64 --pairs 2 --solver cadical --enum-workers 1 --max-enum 100` | 0.077 s | single-worker | `real 0.18`, `user 0.16`, `sys 0.00` | key recovered at solution 2 |
| Hard underconstrained (120r, 1 pair, single worker) | `python sat_solver.py --rounds 120 --pairs 1 --solver cadical --enum-workers 1 --max-enum 100` | 0.049 s | single-worker | `real 3.88`, `user 3.83`, `sys 0.01` | no verified key in 101 solutions |
| Hard underconstrained (120r, 1 pair, parallel) | `python sat_solver.py --rounds 120 --pairs 1 --solver cadical --enum-workers 10 --max-enum 100` | 0.053 s | 10 workers, 16 partitions | `real 1.76`, `user 9.04`, `sys 0.24` | no verified key (`96/96` partition budget exhausted) |

Interpretation:

- CPU parallel enumeration gives a visible wall clock speedup on the same underconstrained instance.
- With one pair at 120 rounds, the candidate space is too large for a small enumeration budget. Parallelism improves throughput but does not make the instance well determined.

### 120-Round Fixed-Bits Sweep (1 Pair, CPU)

Command template:

```bash
/usr/bin/time -p python sat_solver.py --rounds 120 --pairs 1 --solver cadical \
	--fixed-bits <N> --fixed-source correct --max-enum 100 --enum-workers 1
```

Measured on the same macOS system:

| Fixed bits | First SAT solve | First candidate holdout | Enumeration outcome | End-to-end `real` |
|------------|-----------------|-------------------------|---------------------|-------------------|
| 0  | 0.049 s | failed | no verified key found | 3.77 s |
| 8  | 0.054 s | failed | no verified key found | 3.60 s |
| 16 | 0.126 s | failed | no verified key found | 6.31 s |
| 24 | 0.304 s | failed | recovered target key | 6.03 s |
| 26 | 0.369 s | failed | recovered target key | 0.98 s |
| 28 | 0.202 s | failed | recovered target key | 4.44 s |
| 30 | 0.109 s | failed | recovered target key | 4.90 s |
| 32 | 0.170 s | verified | first solution already target | 0.21 s |
| 40 | 0.012 s | verified | first solution already target | 0.05 s |

Takeaway:

- The practical transition occurs around `--fixed-bits 32` for this setup, `120 rounds` and `1 pair`. Below 32, first solutions are usually spurious and require enumeration. At 32 and above, the first candidate is already stable under holdout.
- End to end time below 32 fixed bits is dominated by enumeration and is non monotonic because SAT solution ordering varies between runs.

### 160-Round Fixed-Bits Sweep (1 Pair, CPU)

Command template:

```bash
/usr/bin/time -p python sat_solver.py --rounds 160 --pairs 1 --solver cadical \
	--fixed-bits <N> --fixed-source correct --max-enum 100 --enum-workers 1
```

Measured on the same macOS system:

| Fixed bits | First SAT solve | First candidate holdout | Enumeration outcome | End-to-end `real` |
|------------|-----------------|-------------------------|---------------------|-------------------|
| 24 | 33.307 s | failed | recovered target key | 160.95 s |
| 28 | 72.842 s | failed | recovered target key | 90.93 s |
| 32 | 12.627 s | failed | recovered target key | 14.91 s |
| 36 | 1.067 s | verified | first solution already target | 1.11 s |
| 40 | 0.085 s | verified | first solution already target | 0.13 s |

Takeaway:

- For this harder `160 rounds`, `1 pair` setup, the practical transition moves to about `--fixed-bits 36`. At 32 fixed bits the target key is recoverable, but only after rejecting a spurious first model and enumerating further.
- Runtime is strongly non monotonic below that threshold. In particular, `28` fixed bits is slower than `24` fixed bits on the first SAT solve, which shows that an individual SAT instance can become locally harder even when more side information is added.

## Technical Note on `--slide528`

KeeLoq uses a period-64 key schedule. With a slid pair, that lets the implementation derive two 64-round constraints with different key offsets:

1. $E_{64}(K, P_1) = P_2$ with key offset 0
2. $E'_{64}(K, C_1) = C_2$ with key offset 16

This is algebraically interesting and supported by both the SAT and Groebner tools. It should be read as a study of reduced 64 round components extracted from the full cipher, not as a direct practical full round key recovery attack comparable to the fixed point workflow in `attacks/fixedpoint`.