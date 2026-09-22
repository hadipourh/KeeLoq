# KeeLoq

Reference implementation of KeeLoq in C, with cryptanalysis tools for research and reproducible experiments. The repository includes:

- Polynomial equation generator for KeeLoq over GF(2)
- Algebraic cryptanalysis attacks (Groebner basis and SAT-based key recovery)
- Fixed-point and slide meet-in-the-middle attacks on full 528-round KeeLoq
- Cube searches and empirical cube verification
- A CUDA brute-force baseline

## What is KeeLoq

KeeLoq is a proprietary block cipher owned by [Microchip](https://www.microchip.com/), and is used in remote key-less entry systems from several car manufacturers -such as [Chrysler](https://www.chrysler.com/), [Fiat](https://www.fiat.com/), [GM](https://www.gm.com/), [Honda](https://www.honda.com/), [Toyota](https://www.toyota.com/), [Volvo](https://www.volvocars.com/intl), [VW](https://www.vw.com/), [Jaguar](https://www.jaguar.com/index.html), [Iran Khodro](https://www.ikco.ir/en/), etc.- as well as for garage door openers. After the confidential specifications have been leaked on a Russian website [2] in 2006, several cryptanalysts have found substantial weaknesses in the design of the algorithm and the hardware on which it is implemented [1].

## KeeLoq Encryption

KeeLoq is a block cipher with a 64-bit key and a 32-bit block size. The cipher operates on two registers for 528 clock cycles to produce the ciphertext [1], based on the following shape:

![KeeLoq encryption algorithm](./pictures/KeeLoq-Encryption.svg)

## KeeLoq Decryption

KeeLoq decryption algorithm operates on two registers for 528 rounds, to produce the plaintext for a given key and ciphertext, according to the following shape.

![KeeLoq decryption algorithm](./pictures/KeeLoq-Decryption.svg)

## Building and Usage

### Prerequisites

- The reference C implementation requires a C compiler and Make.
- Python attack tools require Python 3 and the dependencies described below or in the corresponding attack directory.
- GPU implementations require an NVIDIA GPU and the CUDA Toolkit, including `nvcc`. Follow each attack's README for architecture flags and tuning.
- Multithreaded CPU attack tools use POSIX threads. The build commands target Linux and macOS; CUDA execution requires a supported NVIDIA system.

### Building

```bash
git clone https://github.com/hadipourh/KeeLoq
cd KeeLoq
make
```

### Usage

The `keeloq` binary supports the following commands:

```bash
./keeloq              # Demo encryption/decryption
./keeloq speed        # Run encryption speed benchmark
./keeloq polygen      # Generate polynomial equations (outputs to mqkeeloq.txt)
./keeloq polygen-sym  # Generate symbolic equations with P_i_j, C_i_j variables
./keeloq slide528     # Generate slide528 equations (concrete, to mqkeeloq.txt)
./keeloq slide528-sym # Generate slide528 equations (symbolic, to mqkeeloq_symbolic.txt)
./keeloq --help       # Show usage information
```

### Makefile Targets

```bash
make              # Build the project
make release      # Build with optimizations (-O3)
make speed        # Build and run speed benchmark
make polygen      # Build and run equation generator
make clean        # Clean build artifacts
```

## Cryptanalysis

The attack directories provide independent implementations and detailed usage instructions. Algebraic and cube tools support reduced-round experiments; fixed-point and slide meet-in-the-middle tools target full 528-round KeeLoq. The examples generate synthetic data from a specified key for reproducible experiments.

> **Important:** The algebraic tools are **not** presented here as a practical full 528-round attack. They primarily target **reduced-round KeeLoq** instances such as 32 or 64 rounds. For a practical full 528-round attack in this repository, see [attacks/fixedpoint/README.md](attacks/fixedpoint/README.md).

### Requirements

Create a virtual environment and install the Python dependencies for the algebraic tools:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
```

Or install individually:

```bash
python -m pip install passagemath-standard python-sat pycryptosat
```

For the standalone algebraic attack documentation, local Makefile, and self-contained setup, see [attacks/algebraic/README.md](attacks/algebraic/README.md).

### Slide528 Attack

KeeLoq uses 528 rounds with a period-64 key schedule. A slide attack decomposes full KeeLoq as $E_{528} = E'_{64} \circ E_{464} = E_{464} \circ E_{64}$, where $E_{64}$ uses key bits starting at offset 0 and $E'_{64}$ uses key bits starting at offset $464 \bmod 64 = 16$. Given a slid pair $(P_1, P_2)$ where $P_2 = E_{64}(K, P_1)$, and their ciphertexts $C_1 = E_{528}(K, P_1)$, $C_2 = E_{528}(K, P_2)$, we get two 64-round constraints sharing the same key:

1. $E_{64}(K, P_1) = P_2$ with key offset 0
2. $E'_{64}(K, C_1) = C_2$ with key offset 16

The Python solvers support this mode via `--slide528`; the C equation generator uses the `slide528` and `slide528-sym` subcommands:

```bash
# SAT solver
python attacks/algebraic/sat_solver.py --slide528 --solver cryptominisat
python attacks/algebraic/sat_solver.py --slide528 --solver cadical

# Groebner basis
python attacks/algebraic/groebner_solver.py --slide528
python attacks/algebraic/groebner_solver.py --slide528 --use-polygen

# Equation generation (C)
./keeloq slide528       # Concrete equations
./keeloq slide528-sym   # Symbolic equations
```

### SAT-based Attack

Uses SAT solvers (CryptoMiniSat with native XOR support, or CaDiCaL/Glucose via PySAT) to recover the secret key.

```bash
python attacks/algebraic/sat_solver.py --rounds 64 --pairs 1 --solver cryptominisat
python attacks/algebraic/sat_solver.py --rounds 64 --pairs 1 --solver cadical
```

Options:

- `--rounds, -r`: Number of rounds (default: 64)
- `--pairs, -n`: Number of plaintext-ciphertext pairs (default: 1)
- `--solver`: SAT solver to use (`cryptominisat`, `cadical`, `glucose`, `minisat`)
- `--slide528`: Use slide528 decomposition (two 64-round constraints with key offsets 0 and 16)

The NLF encoding uses a minimized 14-clause CNF derived using [SboxAnalyzer](https://github.com/hadipourh/sboxanalyzer).

### Groebner Basis Attack

Uses passagemath to compute a Groebner basis of the polynomial system over GF(2).

```bash
python attacks/algebraic/groebner_solver.py --rounds 32 --pairs 2
python attacks/algebraic/groebner_solver.py --rounds 32 --pairs 2 --use-polygen
```

Options:

- `--rounds, -r`: Number of rounds (default: 32)
- `--pairs, -n`: Number of P/C pairs (default: 1)
- `--use-polygen, -p`: Use polygen equation format (with auxiliary variables)
- `--slide528`: Use slide528 decomposition (two 64-round constraints with key offsets 0 and 16)

### Running via Makefile

```bash
make sat                          # Run SAT solver with default parameters
make groebner                     # Run Groebner solver with default parameters
make -C attacks/fixedpoint attack # Run the full-codebook fixed-point experiment
```

### Fixed-Point Attack (Full 528-Round Key Recovery)

Exploits fixed points of $(E_{64})^8$ to recover the full 64-bit key from the complete codebook. Phase 1 scans $2^{32}$ plaintexts in C or CUDA, and Phase 2 combines exhaustive directed-pair SAT for groups with $n \geq 2$ and exact singleton recovery for groups with $n = 1$ (optionally GPU-prefiltered). Under the random-permutation heuristic, the end-to-end success probability is $1 - e^{-15/8} \approx 84.7\%$, and the current 100-key benchmark in the repository recovered $85/100$ keys, exactly matching the keys with a true phase-1 signal.

```bash
cd attacks/fixedpoint
make attack KEY=0x5CEC6701B79FD949 THREADS=56
```

See [attacks/fixedpoint/README.md](attacks/fixedpoint/README.md) for the exact method, benchmarks, and usage details.

### Slide Meet-in-the-Middle Attack

The [MITM tools](attacks/mitm/README.md) implement slide meet-in-the-middle key recovery on full 528-round KeeLoq, with a generalized CPU reference and CUDA implementations. The directory documentation explains the data requirements, success probability, profiles, and bounded validation commands.

### Cube Experiments

The [cube tools](attacks/cube/README.md) provide monomial-prediction searches and a parallel empirical verifier. Build the verifier from source with `make cube-build`; see the directory documentation for reduced-round experiments and their limitations.

### Brute-Force Baseline (CUDA)

Exhaustive search over the full 64-bit key space using two known plaintext-ciphertext pairs.
Two pairs filter candidate keys but do not guarantee uniqueness; additional pairs can distinguish remaining candidates. The kernel is bit-sliced 32 ways per
thread and applies a waterfall test so the second pair is evaluated only for the rare survivors of
the first, keeping the cost at about one encryption per candidate.

```bash
cd attacks/bruteforce
make
./keeloq_bf --benchmark --fix-low 24
```

This is a baseline rather than a practical attack: even at the measured rate a single-GPU worst-case
full search takes years. See [attacks/bruteforce/README.md](attacks/bruteforce/README.md) for the
benchmark, the GPU-count tables, and the tuning knobs.

## Project Structure

```
KeeLoq/
├── keeloq.c/h         # Core cipher implementation
├── speed.c/h          # Speed benchmarking
├── main.c             # CLI interface
├── makefile           # Build system
├── requirements.txt   # Python dependencies
├── attacks/           # Cryptanalysis implementations
│   ├── algebraic/         # Reduced-round algebraic attacks
│   │   ├── sat_solver.py      # SAT-based reduced-round key recovery
│   │   ├── groebner_solver.py # Groebner basis reduced-round attack
│   │   ├── polygen.c/h        # Polynomial equation generator (C)
│   │   ├── Makefile           # Self-contained local build/run helpers
│   │   └── README.md          # Independent algebraic attack documentation
│   ├── mitm/             # Practical slide+MitM (CPU/GPU, generalized profiles)
│   │   ├── mitm.c            # Baseline CPU attack
│   │   ├── mitm_generalized.c/h # Paper-faithful generalized CPU reference
│   │   ├── mitm_gpu_kp1515.cu   # Recommended GPU profile
│   │   └── README.md          # Usage, benchmarks, and profile guidance
│   ├── fixedpoint/        # Fixed-point attack on full 528-round KeeLoq
│   │   ├── fixedpoint_mt.c    # Phase 1: multithreaded scan + vote
│   │   ├── fixedpoint_gpu.cu  # Phase 1: CUDA scan + vote
│   │   ├── fixedpoint_sat.py  # Phase 2: SAT recovery of k[16..63]
│   │   ├── benchmark.py       # Multi-key benchmark driver
│   │   └── Makefile           # Build & run pipeline
│   ├── bruteforce/        # CUDA exhaustive search over the full 2^64 key space
│   │   ├── keeloq_bruteforce.cu # Bit-sliced GPU kernel
│   │   └── README.md          # Build, benchmark, and cost analysis
│   ├── cube/              # Monomial-prediction search + empirical cube verifier
│   └── library/           # Reference papers
└── pictures/          # Documentation images
```

## Test Vectors

```
key                | plaintext  | ciphertext
0x5cec6701b79fd949 | 0xf741e2db | 0xe44f4cdf
0x5cec6701b79fd949 | 0x0ca69b92 | 0xa6ac0ea2
```

Run `make run` for the encryption/decryption demo and its round-trip verification.

## License

See [LICENSE](LICENSE) for the GNU General Public License, version 3.

## References

[1]- [Robert R. Enderlein, S Vaudenay, P Sepehrdad. KeeLoq. EPFL, Semester Project 2010.](http://www.e7n.ch/data/e10.pdf)

[2]- [Code Hopping Decoder using a PIC16C56](http://keeloq.narod.ru/decryption.pdf)
