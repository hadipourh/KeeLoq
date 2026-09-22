#!/usr/bin/env python3
"""
KeeLoq Monomial Prediction — SAT-based Integral/Cube Distinguisher Search
==========================================================================

Models the monomial prediction / division property of reduced-round KeeLoq
using SAT, following:
  - Hu, Sun, Wang, Wang. "An Algebraic Formulation of the Division Property"
    (ASIACRYPT 2020)
  - Hadipour, Eichlseder. "Integral Cryptanalysis of WARP Based on Monomial
    Prediction" (ToSC 2022)

The NLF monomial-prediction-table (MPT) is generated with SboxAnalyzer.

KeeLoq structure
-----------------
  32-bit block, 64-bit key, configurable rounds (default 528).
  NLFSR feedback:
    L[i+32] = k[i mod 64] ^ L[i] ^ L[i+16] ^ NLF(L[i+31],L[i+26],L[i+20],L[i+9],L[i+1])
  Per-round shift register update (right-shift by 1, feedback enters bit 31):
    s[r+1][j] = s[r][j+1]    for j = 0 .. 30
    s[r+1][31] = feedback

Usage examples
---------------
  # Check a specific cube for R-round KeeLoq
  python keeloq_monomial.py -r 32 -c 0,1,2,3

  # Check a specific (cube, output-bit) pair
  python keeloq_monomial.py -r 32 -c 0,1,2,3 -o 5

  # Systematic search over all d-bit cubes
  python keeloq_monomial.py -r 32 -d 4 --search

  # Restrict search to specific candidate positions
  python keeloq_monomial.py -r 32 -d 4 --search --positions 0,1,2,3,4,5
"""

import sys
import time
import argparse
from itertools import combinations
from pysat.solvers import Solver

# ================================================================
# KeeLoq Constants
# ================================================================

BLOCK_SIZE = 32           # 32-bit state
KEY_SIZE = 64             # 64-bit key
DEFAULT_ROUNDS = 528      # Full KeeLoq = 8*64 + 16

# NLF input taps in order a0 (MSB) .. a4 (LSB)
# In the C code: nlf_input = (L[31]<<4)|(L[26]<<3)|(L[20]<<2)|(L[9]<<1)|L[1]
NLF_POSITIONS = [31, 26, 20, 9, 1]   # a0=L[31], a1=L[26], a2=L[20], a3=L[9], a4=L[1]

# Bit positions that are forked (read by NLF or XOR *and* shifted)
FORKED_NLF = frozenset({1, 9, 20, 26, 31})
FORKED_XOR = frozenset({16})
FORKED_ALL = FORKED_NLF | FORKED_XOR
# Note: position 0 is consumed by the XOR but NOT shifted (falls off the register)

# ================================================================
# NLF Monomial-Prediction-Table CNF  (from SboxAnalyzer)
# ================================================================
#
# Generated with:
#   from sboxanalyzer import SboxAnalyzer
#   tt = [(0x3A5C742E >> i) & 1 for i in range(32)]
#   sa = SboxAnalyzer(tt)
#   cnf, milp, cp = sa.minimized_integral_constraints()
#
# Variables: a0 (MSB, L[31]) .. a4 (LSB, L[1]), b0 (NLF output)
# 10 clauses:
#   (~a0|a1|a2|a4)  (~a1|a2|a3|a4)  (a0|~a1|~a3|~b0)
#   (~a0|~a2|~a3|~b0)  (~a0|~a1|~a4|~b0)  (a0|~a2|~a4|~b0)
#   (~a2|a3|a4|b0)  (a0|a1|a3|a4|~b0)  (~a4|b0)  (~a3|b0)


def nlf_mpt_clauses(a0, a1, a2, a3, a4, b0):
    """
    Return the 10 CNF clauses that encode the KeeLoq NLF MPT.

    Parameters correspond to SAT-variable IDs (positive integers):
      a0 .. a4  –  monomial-indicator for NLF input bits
                   (a0 = L[31] = MSB, a4 = L[1] = LSB)
      b0        –  monomial-indicator for NLF output
    """
    return [
        [-a0,  a1,  a2,       a4      ],   # (~a0 | a1 | a2 | a4)
        [      -a1, a2,  a3,  a4      ],   # (~a1 | a2 | a3 | a4)
        [ a0, -a1,      -a3,      -b0 ],   # (a0 | ~a1 | ~a3 | ~b0)
        [-a0,      -a2, -a3,      -b0 ],   # (~a0 | ~a2 | ~a3 | ~b0)
        [-a0, -a1,            -a4, -b0],   # (~a0 | ~a1 | ~a4 | ~b0)
        [ a0,      -a2,      -a4, -b0 ],   # (a0 | ~a2 | ~a4 | ~b0)
        [      -a2,  a3,  a4,      b0 ],   # (~a2 | a3 | a4 | b0)
        [ a0,  a1,   a3,  a4,     -b0 ],   # (a0 | a1 | a3 | a4 | ~b0)
        [                     -a4, b0 ],   # (~a4 | b0)
        [            -a3,          b0 ],   # (~a3 | b0)
    ]

# ================================================================
# Generic Gate-Level Monomial-Prediction Rules
# (Propositions 1–5 in Hadipour & Eichlseder, SAC 2022)
# ================================================================


def copy_n_clauses(x, copies):
    """
    n-way COPY  x → (y0, y1, …, y_{n-1}).
    Monomial prediction (Proposition 5, Hadipour & Eichlseder 2022):
        u ↔ (v_0 ∨ v_1 ∨ … ∨ v_{n-1})

    Clauses:
      (¬x ∨ y0 ∨ y1 ∨ … ∨ y_{n-1})   –  x active → at least one copy active
      (¬y_i ∨ x)  for each i           –  any copy active → x must be active
    """
    cls = [[-x] + list(copies)]  # x active → some copy active
    for y in copies:
        cls.append([-y, x])     # copy active → x active
    return cls


def copy2_clauses(x, y0, y1):
    """
    2-way COPY  x → (y0, y1).  Special case of copy_n_clauses.
    """
    return copy_n_clauses(x, [y0, y1])


def xor_n_clauses(inputs, output):
    """
    n-input XOR  y = x0 ⊕ x1 ⊕ … ⊕ x_{n-1}.
    Monomial prediction: at most one input active; output active iff
    exactly one input active.

    Clauses:
      • pairwise exclusion   (¬u_i ∨ ¬u_j) for all i < j
      • input → output       (¬u_i ∨ v)    for all i
      • output → some input  (u_0 ∨ u_1 ∨ … ∨ u_{n-1} ∨ ¬v)
    """
    n = len(inputs)
    cls = []
    # pairwise mutual exclusion
    for i in range(n):
        for j in range(i + 1, n):
            cls.append([-inputs[i], -inputs[j]])
    # input implies output
    for u in inputs:
        cls.append([-u, output])
    # output implies at least one input
    cls.append(list(inputs) + [-output])
    return cls


def equal_clauses(x, y):
    """
    Wire equality  x = y  (pure routing, no computation).
    Two clauses:  (¬x ∨ y) ∧ (x ∨ ¬y).
    """
    return [
        [-x, y],
        [x, -y],
    ]

# ================================================================
# KeeLoq Monomial-Prediction SAT Model
# ================================================================


class KeeLoqMonomialModel:
    """
    Builds a SAT model whose satisfying assignments correspond to
    valid monomial trails through *R* rounds of KeeLoq encryption.

    Variable semantics (all binary monomial-indicators):
      s[r][j]  –  state bit j at round boundary r      (r = 0 … R, j = 0 … 31)
      k[i]     –  key bit i                             (i = 0 … 63)

    Per-round auxiliary variables (internal, not exposed):
      nlf_copy[r][0..4]  –  NLF-input copies after COPY fork
      nlf_out[r]         –  NLF output
      xor16[r]           –  XOR-input copy of s[r][16]
    """

    def __init__(self, nrounds):
        self.R = nrounds
        self._next_var = 1
        self.clauses = []

        # ---- allocate state and key variables ----
        self.s = [
            [self._new_var() for _ in range(BLOCK_SIZE)]
            for _ in range(self.R + 1)
        ]
        self.k = [self._new_var() for _ in range(KEY_SIZE)]

        # ---- allocate per-round key-USE copy variables ----
        # Each key bit k[j] may be used in multiple rounds (r where r%64==j).
        # Each such use is a COPY/branch of k[j], so we need a fresh
        # monomial-indicator variable per use.
        self.k_use = [self._new_var() for _ in range(self.R)]

        # ---- build per-round constraints ----
        for r in range(self.R):
            self._add_round(r)

        # ---- add key COPY constraints ----
        # For each key bit k[j], gather all rounds that use it and
        # add n-way COPY:  k[j] → (k_use[r1], k_use[r2], …)
        for j in range(KEY_SIZE):
            copies = [self.k_use[r] for r in range(self.R) if r % KEY_SIZE == j]
            if len(copies) == 1:
                # only one use: simple equality (no branch)
                self.clauses.extend(equal_clauses(self.k[j], copies[0]))
            elif len(copies) > 1:
                # multiple uses: proper n-way COPY
                self.clauses.extend(copy_n_clauses(self.k[j], copies))
            # if copies is empty: key bit k[j] not used (R < j), no constraint

        self.num_vars = self._next_var - 1
        self.num_clauses = len(self.clauses)

    # --------------------------------------------------------
    # internal helpers
    # --------------------------------------------------------

    def _new_var(self):
        v = self._next_var
        self._next_var += 1
        return v

    def _add_round(self, r):
        """
        Add all monomial-prediction constraints for round *r*.

        Operations modelled (per round):
          1.  COPY  for each NLF tap  {31,26,20,9,1}
              s[r][pos] → (nlf_copy, s[r+1][pos-1])
          2.  COPY  for XOR tap at position 16
              s[r][16] → (xor16_copy, s[r+1][15])
          3.  NLF   (a0..a4, b0) via 10-clause MPT
          4.  4-XOR  s[r][0] ⊕ xor16_copy ⊕ nlf_out ⊕ k[r%64] → s[r+1][31]
          5.  Wire equalities for non-forked bits
        """
        # --- 1. COPY for NLF input taps ---
        nlf_copies = []
        for pos in NLF_POSITIONS:
            c = self._new_var()
            nlf_copies.append(c)
            # COPY: s[r][pos] → (nlf_copy c, shift target s[r+1][pos-1])
            self.clauses.extend(
                copy2_clauses(self.s[r][pos], c, self.s[r + 1][pos - 1])
            )

        # --- 2. COPY for XOR tap at position 16 ---
        xor16_copy = self._new_var()
        self.clauses.extend(
            copy2_clauses(self.s[r][16], xor16_copy, self.s[r + 1][15])
        )

        # --- 3. NLF MPT constraint ---
        nlf_out = self._new_var()
        self.clauses.extend(
            nlf_mpt_clauses(
                nlf_copies[0],   # a0 = copy of L[31]
                nlf_copies[1],   # a1 = copy of L[26]
                nlf_copies[2],   # a2 = copy of L[20]
                nlf_copies[3],   # a3 = copy of L[9]
                nlf_copies[4],   # a4 = copy of L[1]
                nlf_out,         # b0 = NLF output
            )
        )

        # --- 4. 4-input XOR → feedback ---
        # feedback = s[r][0] ⊕ copy_of_s[r][16] ⊕ nlf_out ⊕ k[r % 64]
        # Use the per-round key-use copy variable (not the master key var)
        # to correctly model key-bit branching when R > 64.
        self.clauses.extend(
            xor_n_clauses(
                [self.s[r][0], xor16_copy, nlf_out, self.k_use[r]],
                self.s[r + 1][31],
            )
        )

        # --- 5. Wire equalities for non-forked, non-consumed bits ---
        # For j not in {0, 1, 9, 16, 20, 26, 31} and j >= 1:
        #   s[r+1][j-1] = s[r][j]   (pure wire through the shift register)
        # Position 0 is consumed by the XOR only (not shifted).
        # Positions in FORKED_ALL are handled by COPY above.
        for j in range(1, BLOCK_SIZE):
            if j not in FORKED_ALL:
                self.clauses.extend(
                    equal_clauses(self.s[r][j], self.s[r + 1][j - 1])
                )

    # --------------------------------------------------------
    # query helpers
    # --------------------------------------------------------

    def _input_assumptions(self, cube_bits):
        """
        Return SAT assumptions that fix the input (plaintext) monomial
        indicator:  active bits → 1, constant bits → 0.
        """
        cube_set = set(cube_bits)
        assumptions = []
        for j in range(BLOCK_SIZE):
            if j in cube_set:
                assumptions.append(self.s[0][j])        # active
            else:
                assumptions.append(-self.s[0][j])       # constant
        return assumptions

    def _output_assumptions(self, output_bit):
        """
        Return SAT assumptions that set the output monomial indicator
        to the unit vector e_{output_bit}.
        """
        assumptions = []
        for j in range(BLOCK_SIZE):
            if j == output_bit:
                assumptions.append(self.s[self.R][j])   # target
            else:
                assumptions.append(-self.s[self.R][j])  # not targeted
        return assumptions

    # --------------------------------------------------------
    # public API
    # --------------------------------------------------------

    def check_balance(self, cube_bits, output_bit, solver):
        """
        Check whether *output_bit* is balanced (key-independent) for the
        given cube, using the key-independence test of Hu et al. §6.4:

          Fix u = cube indicator, v = e_{output_bit}.
          Add constraint  Σ k_i ≥ 1  (at least one key bit active).
          If UNSAT → no key-dependent monomial trail → balanced.

        Parameters
        ----------
        cube_bits  : iterable of int  –  active plaintext positions
        output_bit : int  –  ciphertext bit to test (0 .. 31)
        solver     : pysat Solver instance (pre-loaded with model clauses)

        Returns
        -------
        True   if the output bit is provably balanced  (UNSAT)
        False  if a monomial trail was found            (SAT)
        """
        assumptions = (
            self._input_assumptions(cube_bits)
            + self._output_assumptions(output_bit)
        )
        result = solver.solve(assumptions=assumptions)
        return not result   # UNSAT → balanced

    def find_balanced_bits(self, cube_bits, solver):
        """
        Find all output bits that are balanced for a given cube.
        Reuses the same solver for all 32 output-bit queries.

        Returns
        -------
        list of int  –  indices of balanced output bits
        """
        in_assum = self._input_assumptions(cube_bits)
        balanced = []
        for j in range(BLOCK_SIZE):
            out_assum = self._output_assumptions(j)
            result = solver.solve(assumptions=in_assum + out_assum)
            if not result:
                balanced.append(j)
        return balanced

    def search_cubes(self, cube_dim, solver, positions=None,
                     max_cubes=None, verbose=True):
        """
        Systematic search: enumerate all *cube_dim*-sized cubes from
        *positions* and report which output bits are balanced.

        Returns
        -------
        dict : frozenset → list[int]
            Maps each successful cube to its list of balanced output bits.
        """
        if positions is None:
            positions = list(range(BLOCK_SIZE))

        results = {}
        tested = 0
        t_start = time.time()

        for combo in combinations(positions, cube_dim):
            cube = frozenset(combo)
            balanced = self.find_balanced_bits(cube, solver)
            tested += 1

            if balanced:
                results[cube] = balanced
                if verbose:
                    elapsed = time.time() - t_start
                    cube_label = str(sorted(cube))
                    print(f"  [{elapsed:7.1f}s] Cube {cube_label:>40s}  "
                          f"→ {len(balanced)} balanced bits: {balanced}")

            if verbose and tested % 200 == 0:
                elapsed = time.time() - t_start
                print(f"  [{elapsed:7.1f}s] tested {tested} cubes, "
                      f"{len(results)} have balanced bits ...")

            if max_cubes is not None and tested >= max_cubes:
                break

        return results


def make_solver(model, solver_name='cadical195'):
    """
    Create a SAT solver pre-loaded with the model clauses and the
    key-independence constraint  (k_0 ∨ k_1 ∨ … ∨ k_63).
    """
    key_clause = list(model.k)          # at least one key bit active
    all_clauses = model.clauses + [key_clause]
    return Solver(name=solver_name, bootstrap_with=all_clauses)

# ================================================================
# CLI
# ================================================================


def main():
    parser = argparse.ArgumentParser(
        description='KeeLoq Monomial Prediction – SAT-based cube/integral '
                    'distinguisher search',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s -r 32 -c 0,1,2,3
  %(prog)s -r 32 -c 0,1,2,3 -o 5
  %(prog)s -r 32 -d 4 --search
  %(prog)s -r 64 -d 6 --search --positions 0,1,9,16,20,26
""",
    )
    parser.add_argument('-r', '--rounds', type=int, required=True,
                        help='Number of KeeLoq rounds')
    parser.add_argument('-c', '--cube', type=str, default=None,
                        help='Comma-separated cube bit positions (e.g. "0,1,2,3")')
    parser.add_argument('-o', '--output-bit', type=int, default=None,
                        help='Specific output bit to check (0-31)')
    parser.add_argument('-d', '--cube-dim', type=int, default=None,
                        help='Cube dimension for systematic search')
    parser.add_argument('--search', action='store_true',
                        help='Systematic search over all cubes of given dimension')
    parser.add_argument('--max-cubes', type=int, default=None,
                        help='Cap on number of cubes tested in search mode')
    parser.add_argument('--solver', type=str, default='cadical195',
                        help='PySAT solver backend (default: cadical195)')
    parser.add_argument('--positions', type=str, default=None,
                        help='Restrict cube positions (comma-separated)')
    args = parser.parse_args()

    # ---- build model ----
    print(f"Building monomial-prediction model for {args.rounds}-round KeeLoq ...")
    t0 = time.time()
    model = KeeLoqMonomialModel(args.rounds)
    t_build = time.time() - t0
    print(f"  Variables : {model.num_vars}")
    print(f"  Clauses   : {model.num_clauses}")
    print(f"  Build time: {t_build:.3f} s")

    # ---- create solver ----
    solver = make_solver(model, args.solver)

    # ---- dispatch ----
    if args.cube is not None:
        cube_bits = list(map(int, args.cube.split(',')))
        print(f"\nCube: {sorted(cube_bits)}  (dimension {len(cube_bits)})")

        if args.output_bit is not None:
            t0 = time.time()
            bal = model.check_balance(cube_bits, args.output_bit, solver)
            t_s = time.time() - t0
            tag = "BALANCED (key-independent)" if bal else "NOT proven balanced"
            print(f"  Output bit {args.output_bit}: {tag}  [{t_s:.3f} s]")
        else:
            print("Checking all 32 output bits ...")
            t0 = time.time()
            balanced = model.find_balanced_bits(cube_bits, solver)
            t_s = time.time() - t0
            if balanced:
                print(f"  Balanced output bits: {balanced}")
            else:
                print(f"  No balanced output bits found.")
            print(f"  Solve time: {t_s:.3f} s")

    elif args.search and args.cube_dim is not None:
        positions = None
        if args.positions:
            positions = list(map(int, args.positions.split(',')))

        from math import comb
        n_pos = len(positions) if positions else BLOCK_SIZE
        total_combos = comb(n_pos, args.cube_dim)
        print(f"\nSearching all {args.cube_dim}-bit cubes "
              f"(up to {total_combos} combinations) ...")
        t0 = time.time()
        results = model.search_cubes(
            args.cube_dim, solver,
            positions=positions,
            max_cubes=args.max_cubes,
            verbose=True,
        )
        t_s = time.time() - t0

        print(f"\n{'='*60}")
        print(f"Results: {len(results)} cubes with balanced output bits "
              f"({t_s:.1f} s)")
        for cube, bits in sorted(results.items(),
                                 key=lambda x: (-len(x[1]), sorted(x[0]))):
            cube_label = str(sorted(cube))
            print(f"  {cube_label:>40s}  →  {len(bits)} balanced: {bits}")
    else:
        parser.print_help()

    solver.delete()


if __name__ == '__main__':
    main()
