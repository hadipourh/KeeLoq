# KeeLoq
An implementation of KeeLoq in C programming language. Besides encryption and decryption functions, this implementation contains:
- Polynomial equation generator for KeeLoq over GF(2)
- Algebraic cryptanalysis attacks (Groebner basis and SAT-based key recovery)

## What is KeeLoq
KeeLoq is a proprietary block cipher owned by [Microchip](https://www.microchip.com/), and is used in remote key-less entry systems from several car manufacturers -such as [Chrysler](https://www.chrysler.com/), [Fiat](https://www.fiat.com/), [GM](https://www.gm.com/), [Honda](https://www.honda.com/), [Toyota](https://www.toyota.com/), [Volvo](https://www.volvocars.com/intl), [VW](https://www.vw.com/), [Jaguar](https://www.jaguar.com/index.html), [Iran Khodro](https://www.ikco.ir/en/), etc.- as well as for garage door openers. After the confidential specifications have been leaked on a Russian website [2] in 2006, several cryptanalysts have found substantial weaknesses in the design of the algorithm and the hardware on which it is implemented [1]. 

## KeeLoq Encryption
KeeLoq is a block cipher with a 64-bit key and a 32-bit block size. The cipher operates on two registers for 528 clock cycles to produce the ciphertext [1], based on the following shape: 

![KeeLoq encryption algorithm)](./pictures/KeeLoq-Encryption.svg)


## KeyLoq Decryption
KeeLoq decryption algorithm operates on two registers for 528 rounds, to produce the plaintext for a given key and ciphertext, according to the following shape. 

![KeeLoq encryption algorithm)](./pictures/KeeLoq-Decryption.svg)

## Building and Usage
### Building
```bash
git clone https://github.com/hadipourh/KeeLoq
cd KeeLoq
make
```

### Usage
The `keeloq` binary supports three modes:

```bash
./keeloq              # Demo encryption/decryption
./keeloq speed        # Run encryption speed benchmark
./keeloq polygen      # Generate polynomial equations (outputs to mqkeeloq.txt)
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

## Cryptanalysis Attacks

This project includes two algebraic attack implementations for key recovery:

### Requirements
Install Python dependencies:
```bash
pip install -r requirements.txt
```

Or install individually:
```bash
pip install passagemath-standard python-sat pycryptosat
```

### SAT-based Attack
Uses SAT solvers (CryptoMiniSat with native XOR support, or CaDiCaL/Glucose via PySAT) to recover the secret key.

```bash
python attacks/sat_solver.py --rounds 64 --pairs 1 --solver cryptominisat
python attacks/sat_solver.py --rounds 64 --pairs 1 --solver cadical
```

Options:
- `--rounds, -r`: Number of rounds (default: 64)
- `--pairs, -n`: Number of plaintext-ciphertext pairs (default: 1)
- `--solver`: SAT solver to use (`cryptominisat`, `cadical`, `glucose4`, `minisat22`)

The NLF encoding uses a minimized 14-clause CNF derived using [SboxAnalyzer](https://github.com/hadipourh/sboxanalyzer).

### Groebner Basis Attack
Uses passagemath to compute a Groebner basis of the polynomial system over GF(2).

```bash
python attacks/groebner_solver.py --rounds 32 --pairs 2
python attacks/groebner_solver.py --rounds 32 --pairs 2 --use-polygen
```

Options:
- `--rounds, -r`: Number of rounds (default: 32)
- `--pairs, -n`: Number of P/C pairs (default: 1)
- `--use-polygen, -p`: Use polygen equation format (with auxiliary variables)

### Running via Makefile
```bash
make sat          # Run SAT solver with default parameters
make groebner     # Run Groebner solver with default parameters
```

## Project Structure
```
KeeLoq/
├── keeloq.c/h        # Core cipher implementation
├── speed.c/h         # Speed benchmarking
├── main.c            # CLI interface
├── makefile          # Build system
├── requirements.txt  # Python dependencies
├── attacks/          # Cryptanalysis implementations
│   ├── polygen.c/h       # Polynomial equation generator (C)
│   ├── sat_solver.py     # SAT-based key recovery
│   └── groebner_solver.py # Groebner basis attack
└── pictures/         # Documentation images
```

## Test Vectors

```
key                | plaintext  | ciphertext 
0x5cec6701b79fd949 | 0xf741e2db | 0xe44f4cdf
0x5cec6701b79fd949 | 0x0ca69b92 | 0xa6ac0ea2                                  
```
###

## References
[1]- [Robert R. Enderlein, S Vaudenay, P Sepehrdad. KeeLoq. EPFL, Semester Project 2010.](http://www.e7n.ch/data/e10.pdf)

[2]- [Code Hopping Decoder using a PIC16C56](http://keeloq.narod.ru/decryption.pdf)