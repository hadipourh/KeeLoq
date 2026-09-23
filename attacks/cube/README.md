# Cube / Integral Search for KeeLoq

This folder contains a small SAT-based workflow for searching cube or integral distinguishers on reduced-round KeeLoq and then checking the discovered cubes empirically.

The implementation follows the monomial-prediction point of view on division property style analysis: instead of constructing the full ANF of reduced-round KeeLoq, we track whether a monomial trail can propagate from a chosen input cube to a chosen output bit while allowing key variables to appear. If no such trail exists, the output bit is provably key-independent for that cube.

The background behind this modeling approach is described in:

- Hosein Hadipour and Maria Eichlseder, Integral Cryptanalysis of WARP based on Monomial Prediction, IACR Transactions on Symmetric Cryptology 2022(2), DOI: 10.46586/tosc.v2022.i2.92-112
- Kai Hu, Siwei Sun, Meiqin Wang, and Qingju Wang, An Algebraic Formulation of the Division Property: Revisiting Degree Evaluations, Cube Attacks, and Key-Independent Sums, ASIACRYPT 2020, DOI: 10.1007/978-3-030-64837-4_15

This README only gives the practical idea and the KeeLoq-specific modeling choices used in this folder.

## Core Files

- `Makefile`: local build and run helpers for the empirical verifier
- `keeloq_monomial.py`: main SAT model and search tool
- `verify_cube_par.c`: main empirical verifier for a discovered cube
- `gen_nlf_mpt.py`: helper script that derives the NLF monomial-prediction table and CNF constraints
- `verify_dim31.py`: optional dim-31 wrapper that compares SAT predictions against the C verifier

If you only care about the core workflow, the two important files are `keeloq_monomial.py` and `verify_cube_par.c`.

## Requirements

### Python

- Python 3
- `python-sat`

Install the dependency with:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install python-sat
```

Run these setup commands and the Python examples from the repository root. `gen_nlf_mpt.py` uses only the standard library. The local Makefile prefers `../../venv/bin/python` if it exists and otherwise uses `python3` from the active environment; `VENV=../../.venv` selects the environment above explicitly.

### C

- GCC or Clang
- pthreads

## Quick Start

### 1. Test one cube with the SAT model

```bash
python attacks/cube/keeloq_monomial.py -r 32 -c 0,1,2,3
```

This reports all output bits that are proven key-independent for that 4-bit cube.

The CLI calls them `BALANCED (key-independent)`, but its SAT query proves **key-independence of the cube sum**, not necessarily a zero sum. The model fixes all non-cube plaintext bits to zero; it does not prove the same result for arbitrary nonzero assignments outside the cube.

### 2. Test one cube/output-bit pair

```bash
python attacks/cube/keeloq_monomial.py -r 32 -c 0,1,2,3 -o 5
```

### 3. Search systematically over cubes of fixed dimension

```bash
python attacks/cube/keeloq_monomial.py -r 32 -d 4 --search
```

You can also restrict the candidate positions:

```bash
python attacks/cube/keeloq_monomial.py -r 32 -d 4 --search --positions 0,1,2,3,4,5
```

### 4. Verify a discovered cube empirically

```bash
cd attacks/cube
make build
make verify CUBE='0 1 2 3' ROUNDS=32 NKEYS=5 SEED=42
```

From the repository root you can also run:

```bash
make cube-build
make cube-verify CUBE='0 1 2 3' ROUNDS=32 NKEYS=5 SEED=42
```

If you want to invoke the binary directly after building it, you can still run:

```bash
./verify_cube_par 32 5 42 0 1 2 3
```

## Monomial Prediction in This Folder

Monomial prediction studies whether a monomial at the input can contribute to a monomial at the output without expanding the full ANF of the whole cipher. The basic idea is to write the cipher as a composition of small functions whose monomial propagation is already known, then connect these local propagations across rounds.

The central object is a monomial trail. If the cipher is written as

```math
f = f_r \circ f_{r-1} \circ \cdots \circ f_1,
```

then a monomial trail is a sequence

```math
\pi_{u^{(0)}}(x^{(0)}) \to \pi_{u^{(1)}}(x^{(1)}) \to \cdots \to \pi_{u^{(r)}}(x^{(r)}),
```

where each step is allowed by the local monomial-propagation rule of the corresponding small function. Here, $\pi_{u^{(i)}}(x^{(i)})$ means the monomial described by the binary pattern $u^{(i)}$ in the intermediate variables $x^{(i)}$.

For KeeLoq, the round function is decomposed into simple pieces such as copy nodes, XOR nodes, wire equalities, and the 5-bit NLF. At each round boundary we represent a monomial by binary indicator variables: a variable is `1` if the corresponding state bit or key bit is present in the current monomial, and `0` otherwise. A satisfying assignment of all these indicator variables therefore describes one possible monomial trail through the cipher. This folder uses a SAT encoding of those trail constraints; the same monomial-trail idea can also be expressed in MILP, but that is not what is implemented here.

The local propagation rules of each small function are translated into SAT or MILP constraints:

- copy constraints describe how one active monomial can branch into several uses of the same bit
- XOR constraints describe which input monomials can produce an output monomial
- equality constraints route monomials through the shift register
- the NLF is encoded with constraints derived from its monomial-prediction table

After linking all rounds together, we fix:

- the input monomial corresponding to the chosen cube
- the output monomial corresponding to the target output bit
- additional conditions on the key variables

So, for example, the solver is asked whether there exists a trail of the form

```math
\pi_u(s^{(0)})\,\pi_v(k) \to \cdots \to \pi_{e_j}(s^{(R)}),
```

where $u$ encodes the chosen cube, $v$ encodes the allowed key activity, and $e_j$ is the unit vector selecting output bit $j$.

Then solving the model answers whether a compatible monomial trail exists.

- if no trail with any active key bit exists, the output bit is key-independent for that cube
- if no trail with two or more active key bits exists, the corresponding superpoly is at most linear in the key
- if such trails do exist, the bit is not proven key-independent or linear by this test

The important scientific nuance is that this is a no-false-alarm test based on trail existence. `UNSAT` is the strong conclusion: it proves that no trail of the requested kind exists, so the corresponding monomial is absent. `SAT` only means the model found at least one compatible trail; it does not by itself prove that the monomial survives cancellation in the full ANF.

## What the SAT Query Proves

The main query fixes:

- an input cube, represented as active plaintext bit positions
- one output bit, represented as a unit vector at the final state
- a cardinality condition on the key variables

The key condition is what turns a generic trail search into a useful test.

- to test key-independence, we add $\sum_i k_i \ge 1$
- to test whether the superpoly is at most linear in the key, we add $\sum_i k_i \ge 2$

Then the solver answers:

- with $\sum_i k_i \ge 1$:
  - `SAT`: there exists a monomial trail involving at least one key bit, so the output is not proven key-independent
  - `UNSAT`: no such trail exists, so the output bit is key-independent for that cube
- with $\sum_i k_i \ge 2$:
  - `SAT`: there exists a trail involving at least two key bits, so the superpoly may have degree at least 2 in the key
  - `UNSAT`: no such trail exists, so every surviving key-dependent monomial uses at most one key bit, which means the superpoly is at most linear in the key

In reduced-round settings one can also restrict this cardinality constraint to only the key bits that are actually used in the analyzed rounds. This is exactly the kind of upper-bound test implemented in SAT-based degree or linearity classification: `UNSAT` proves absence of higher-degree key dependence, while `SAT` only shows that such dependence is not ruled out by the trail model.

The current `make_solver()` implements only the $\sum_i k_i\geq1$ query. The $\geq2$ linearity test describes an extension of the method, not an available CLI mode.

The helper methods in `keeloq_monomial.py` use this to:

- test one cube/output-bit pair
- list all key-independent output bits for one cube
- search systematically over cubes of a fixed dimension

## KeeLoq-Specific Encoding

KeeLoq is modeled as a 32-bit NLFSR with 64-bit key and round update

```math
L[i+32] = k[i \bmod 64] \oplus L[i] \oplus L[i+16] \oplus \mathrm{NLF}(L[i+31], L[i+26], L[i+20], L[i+9], L[i+1]).
```

The SAT variables in `keeloq_monomial.py` are monomial indicators:

- `s[r][j]`: state bit `j` at round boundary `r`
- `k[i]`: master-key bit `i`
- auxiliary variables for copied taps, NLF outputs, and per-round key uses

The important modeling choice is that each round is broken into small operations whose monomial propagation rules are known.

### How Basic Operations Are Modeled

#### Copy / Branching

Whenever one state bit is both shifted forward and used elsewhere in the same round, the model treats this as a copy node. For example, KeeLoq taps such as bits 31, 26, 20, 9, 1, and 16 are forked.

Monomial-prediction rule:

```math
u \leftrightarrow v_0 \lor v_1 \lor \cdots \lor v_{n-1}.
```

This means an active monomial on the input wire must activate at least one outgoing branch, and any active outgoing branch requires the source to be active.

#### XOR

The KeeLoq feedback bit is modeled as an XOR of four inputs:

- state bit 0
- copied state bit 16
- NLF output
- the round key bit

For an XOR node

```math
v = u_0 \oplus u_1 \oplus \cdots \oplus u_{n-1},
```

the monomial-prediction rule is: at most one input monomial can be active, and the output monomial is active iff exactly one input monomial is active. In CNF, this is encoded as

```math
\bigwedge_{i<j}(\neg u_i \vee \neg u_j)
\;\wedge\;
\bigwedge_i(\neg u_i \vee v)
\;\wedge\;
(u_0 \vee u_1 \vee \cdots \vee u_{n-1} \vee \neg v).
```

So the first group of clauses enforces the no-collision condition, the second group says an active input forces an active output, and the last clause says an active output must come from at least one active input.

#### Wire Equality / Shift

Non-forked bits simply move through the register. Those transitions are modeled as equalities between the source bit in round `r` and the shifted destination bit in round `r+1`.

#### Nonlinear Function via an MPT

The KeeLoq NLF is a 5-to-1 Boolean function on taps `(31, 26, 20, 9, 1)`. Instead of re-deriving propagation rules by hand for each query, the tool uses a monomial-prediction table for the NLF and encodes the valid transitions as CNF clauses.

The minimized constraints were derived with [SboxAnalyzer](https://github.com/hadipourh/sboxanalyzer). If we denote the NLF-input monomial indicators by $a_0, a_1, a_2, a_3, a_4$ and the output indicator by $b_0$, the resulting CNF used in the code is:

```math
\begin{aligned}
&(\neg a_0 \vee a_1 \vee a_2 \vee a_4)
\wedge (\neg a_1 \vee a_2 \vee a_3 \vee a_4)
\wedge (a_0 \vee \neg a_1 \vee \neg a_3 \vee \neg b_0) \\
&\wedge (\neg a_0 \vee \neg a_2 \vee \neg a_3 \vee \neg b_0)
\wedge (\neg a_0 \vee \neg a_1 \vee \neg a_4 \vee \neg b_0)
\wedge (a_0 \vee \neg a_2 \vee \neg a_4 \vee \neg b_0) \\
&\wedge (\neg a_2 \vee a_3 \vee a_4 \vee b_0)
\wedge (a_0 \vee a_1 \vee a_3 \vee a_4 \vee \neg b_0)
\wedge (\neg a_4 \vee b_0)
\wedge (\neg a_3 \vee b_0).
\end{aligned}
```

That CNF is embedded directly in `keeloq_monomial.py`. The helper script `gen_nlf_mpt.py` shows how the truth table, ANF, and valid transitions were derived.

### Key Schedule Handling

KeeLoq reuses key bits with period 64. In the SAT model, a master-key variable `k[i]` is not plugged into multiple rounds directly. Instead, each round gets its own key-use variable, and the model connects all uses of the same master-key bit through copy constraints.

This matters once the round count exceeds 64, because key-bit reuse is itself a branching structure that monomial prediction must respect.

## Empirical Verification

`verify_cube_par.c` is the main practical verifier.

Given a round count and a list of cube bit positions, it:

- enumerates all $2^d$ plaintexts in the cube
- encrypts them for several random keys
- XOR-sums the ciphertexts
- reports which output bits are always zero-sum (`BALANCED`)
- reports which output bits are constant across all tested keys, whether always 0 or always 1 (`KEY_INDEPENDENT`)

The code parallelizes the cube enumeration across CPU cores with pthreads.

All plaintext bits outside the cube are zero. `KEY_INDEPENDENT` in the C output means constant across the sampled keys; that empirical result alone is not a proof for every key. Likewise, `BALANCED` means zero for all keys tested in that run.

`verify_dim31.py` is only a convenience wrapper for the special case of dimension-31 cubes. It compiles the C verifier if needed, runs it, and compares the result against the SAT prediction. It is useful for regression checks, but it is not part of the minimal workflow.

A dimension-31 run evaluates $2^{31}$ plaintexts per key and round count and can be expensive. The wrapper's default timeout is 1,200 seconds per empirical round test; use the 4-bit quick-start cube for a smoke test.

## Local Makefile

The folder includes a small local `Makefile` for the empirical verifier.

```bash
cd attacks/cube
make build
make verify CUBE='0 1 2 3' ROUNDS=32 NKEYS=5 SEED=42
make dim31 CONST_BIT=31
make clean
```

The most useful targets are:

- `make build`: compile `verify_cube_par`
- `make verify`: run the C verifier on one cube
- `make dim31`: run the optional `verify_dim31.py` wrapper
- `make clean`: remove the verifier binary

At the repository root, the corresponding forwarding targets are `make cube-build`, `make cube-verify`, and `make cube-dim31`.

The underlying verifier arguments are:

```text
verify_cube_par <rounds> <nkeys> <seed> <cube_bit0> [cube_bit1 ...]
```

For a large cube, the verifier uses all available CPU cores unless `NTHREADS` is set.

If you want to invoke the binary directly after building it, you can still run:

```bash
./verify_cube_par 32 5 42 0 1 2 3
```

## Recommended Workflow

1. Use `keeloq_monomial.py` to search for promising cubes or to evaluate a manually chosen cube.
2. Take the discovered cube and validate it with `verify_cube_par.c` on several random keys.
3. If you want an automated SAT-vs-empirical comparison for the dim-31 case, use `verify_dim31.py`.

## Notes

- The SAT model is aimed at reduced-round analysis, not full 528-round practical attacks.
- The approach is intentionally structural: it reasons about the presence or absence of monomial trails through KeeLoq's basic operations rather than constructing the full ANF.
- `gen_nlf_mpt.py` is mainly a reproducibility helper. Most users do not need to run it during normal cube searches.
