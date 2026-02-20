#!/usr/bin/env python3
"""
KeeLoq SAT-based Key Recovery

Uses SAT solvers to recover the secret key from plaintext-ciphertext pairs.
Supports CryptoMiniSat (native XOR) and PySAT (CaDiCaL, Glucose, etc.)

Requirements:
    pip install pycryptosat python-sat

Usage:
    python sat_solver.py [--rounds N] [--solver NAME] [--pairs N]

Author: H. Hadipour
"""

import argparse
import sys
import time
from typing import Optional, List, Tuple, Dict

# KeeLoq NLF lookup constant
NLF_CONSTANT = 0x3A5C742E


def nlf(x4: int, x3: int, x2: int, x1: int, x0: int) -> int:
    """KeeLoq Non-Linear Function."""
    index = (x4 << 4) | (x3 << 3) | (x2 << 2) | (x1 << 1) | x0
    return (NLF_CONSTANT >> index) & 1


def keeloq_encrypt(key: int, plaintext: int, rounds: int = 528) -> int:
    """KeeLoq encryption."""
    state = plaintext
    for i in range(rounds):
        nlf_out = nlf(
            (state >> 31) & 1, (state >> 26) & 1, (state >> 20) & 1,
            (state >> 9) & 1, (state >> 1) & 1
        )
        key_bit = (key >> (i % 64)) & 1
        feedback = key_bit ^ ((state >> 16) & 1) ^ (state & 1) ^ nlf_out
        state = ((state >> 1) | (feedback << 31)) & 0xFFFFFFFF
    return state


class KeeLoqSAT:
    """
    SAT encoding for KeeLoq cipher.
    
    Variable numbering (1-indexed for DIMACS):
        - k[0..63]: key bits (1-64)
        - For each P/C pair p:
            - L[p][0..31+rounds-1]: state bits
    """
    
    def __init__(self, rounds: int, num_pairs: int = 1):
        self.rounds = rounds
        self.num_pairs = num_pairs
        self.num_state = 32 + rounds
        
        # Variable allocation
        self.next_var = 1
        
        # Key variables (shared)
        self.k = list(range(1, 65))
        self.next_var = 65
        
        # State variables per pair
        self.L = []
        for p in range(num_pairs):
            pair_vars = list(range(self.next_var, self.next_var + self.num_state))
            self.L.append(pair_vars)
            self.next_var += self.num_state
        
        # Auxiliary variables for NLF (allocated on demand)
        self.aux_vars = {}
        
    def new_var(self) -> int:
        """Allocate a new variable."""
        v = self.next_var
        self.next_var += 1
        return v
    
    def get_nlf_cnf(self, x4: int, x3: int, x2: int, x1: int, x0: int) -> Tuple[int, List[List[int]]]:
        """
        Encode NLF as CNF clauses using minimized representation.
        
        Returns (output_var, clauses).
        
        The CNF was derived using SboxAnalyzer (https://github.com/hadipourh/sboxanalyzer)
        with encode_set_of_binary_vectors() on the NLF truth table.
        This reduces the encoding from 32 clauses to just 14 clauses.
        
        SboxAnalyzer variable mapping (MSB-first):
            sa_x0, sa_x1, sa_x2, sa_x3, sa_x4 -> x4, x3, x2, x1, x0 (our vars)
            sa_x5 -> out
        """
        # Check cache
        key = (x4, x3, x2, x1, x0)
        if key in self.aux_vars:
            return self.aux_vars[key], []
        
        out = self.new_var()
        self.aux_vars[key] = out
        
        # Minimized CNF for NLF (14 clauses instead of 32)
        # Original from SboxAnalyzer: x0||x1||x2||x3||x4||x5 (MSB first)
        # Mapping: sa_x0=x4, sa_x1=x3, sa_x2=x2, sa_x3=x1, sa_x4=x0, sa_x5=out
        clauses = [
            [x3, x2, -x1, out],           # (x1 | x2 | ~x3 | x5)
            [-x3, -x2, x1, out],          # (~x1 | ~x2 | x3 | x5)
            [-x4, -x3, -x2, -x1, -out],   # (~x0 | ~x1 | ~x2 | ~x3 | ~x5)
            [x4, x3, -x2, -x1, -out],     # (x0 | x1 | ~x2 | ~x3 | ~x5)
            [x4, -x3, x2, x1, -out],      # (x0 | ~x1 | x2 | x3 | ~x5)
            [-x4, x3, x2, x1, -out],      # (~x0 | x1 | x2 | x3 | ~x5)
            [-x4, x3, -x2, -x0, -out],    # (~x0 | x1 | ~x2 | ~x4 | ~x5)
            [x4, -x3, -x1, -x0, -out],    # (x0 | ~x1 | ~x3 | ~x4 | ~x5)
            [-x4, -x3, x2, x0, -out],     # (~x0 | ~x1 | x2 | x4 | ~x5)
            [x4, x3, x1, x0, -out],       # (x0 | x1 | x3 | x4 | ~x5)
            [-x4, -x3, x2, -x0, out],     # (~x0 | ~x1 | x2 | ~x4 | x5)
            [x4, x3, x1, -x0, out],       # (x0 | x1 | x3 | ~x4 | x5)
            [-x4, x3, -x2, x0, out],      # (~x0 | x1 | ~x2 | x4 | x5)
            [x4, -x3, -x1, x0, out],      # (x0 | ~x1 | ~x3 | x4 | x5)
        ]
        
        return out, clauses
    
    def get_xor_cnf(self, lits: List[int], rhs: int) -> List[List[int]]:
        """
        Encode XOR as CNF: lits[0] ^ lits[1] ^ ... = rhs
        
        For 2 variables: a ^ b = rhs
            rhs=0: (a v b)(-a v -b)
            rhs=1: (a v -b)(-a v b)
        
        For n variables: use Tseitin with auxiliary vars
        """
        if len(lits) == 0:
            return [[]] if rhs == 1 else []
        
        if len(lits) == 1:
            return [[lits[0]]] if rhs == 1 else [[-lits[0]]]
        
        if len(lits) == 2:
            a, b = lits
            if rhs == 0:  # a ^ b = 0 means a = b
                return [[a, -b], [-a, b]]
            else:  # a ^ b = 1 means a != b
                return [[a, b], [-a, -b]]
        
        # For longer XORs, chain them
        # (a ^ b) = t1, (t1 ^ c) = t2, ..., final = rhs
        clauses = []
        current = lits[0]
        
        for i in range(1, len(lits)):
            next_lit = lits[i]
            if i == len(lits) - 1:
                # Last XOR: current ^ next_lit = rhs
                if rhs == 0:  # current ^ next_lit = 0 means current = next_lit
                    clauses.extend([[current, -next_lit], [-current, next_lit]])
                else:  # current ^ next_lit = 1 means current != next_lit
                    clauses.extend([[current, next_lit], [-current, -next_lit]])
            else:
                # Intermediate: current ^ next_lit = aux
                aux = self.new_var()
                clauses.extend([
                    [-current, -next_lit, -aux],
                    [-current, next_lit, aux],
                    [current, -next_lit, aux],
                    [current, next_lit, -aux]
                ])
                current = aux
        
        return clauses
    
    def build_cnf(self, plaintexts: List[int], ciphertexts: List[int]) -> List[List[int]]:
        """Build CNF encoding of KeeLoq."""
        clauses = []
        
        for p in range(self.num_pairs):
            pt = plaintexts[p]
            ct = ciphertexts[p]
            L = self.L[p]
            
            # Initial state = plaintext
            for j in range(32):
                bit = (pt >> j) & 1
                if bit:
                    clauses.append([L[j]])
                else:
                    clauses.append([-L[j]])
            
            # Round function
            for i in range(self.rounds):
                j = 32 + i
                
                # NLF inputs
                x4, x3, x2, x1, x0 = L[j-1], L[j-6], L[j-12], L[j-23], L[j-31]
                
                # NLF output
                nlf_out, nlf_clauses = self.get_nlf_cnf(x4, x3, x2, x1, x0)
                clauses.extend(nlf_clauses)
                
                # Feedback: L[j] = k[i%64] ^ L[j-16] ^ L[j-32] ^ nlf_out
                # Rearrange: L[j] ^ k[i%64] ^ L[j-16] ^ L[j-32] ^ nlf_out = 0
                lits = [L[j], self.k[i % 64], L[j-16], L[j-32], nlf_out]
                clauses.extend(self.get_xor_cnf(lits, 0))
            
            # Final state = ciphertext
            for j in range(32):
                bit = (ct >> j) & 1
                state_idx = self.rounds + j
                if bit:
                    clauses.append([L[state_idx]])
                else:
                    clauses.append([-L[state_idx]])
        
        return clauses
    
    def build_xor_clauses(self, plaintexts: List[int], ciphertexts: List[int]) -> Tuple[List[List[int]], List[Tuple[List[int], bool]]]:
        """
        Build clauses for CryptoMiniSat with native XOR support.
        
        Returns (cnf_clauses, xor_clauses)
        """
        cnf_clauses = []
        xor_clauses = []
        
        for p in range(self.num_pairs):
            pt = plaintexts[p]
            ct = ciphertexts[p]
            L = self.L[p]
            
            # Initial state = plaintext (unit clauses)
            for j in range(32):
                bit = (pt >> j) & 1
                cnf_clauses.append([L[j] if bit else -L[j]])
            
            # Round function
            for i in range(self.rounds):
                j = 32 + i
                
                # NLF inputs
                x4, x3, x2, x1, x0 = L[j-1], L[j-6], L[j-12], L[j-23], L[j-31]
                
                # NLF as CNF (can't use native XOR for NLF)
                nlf_out, nlf_cnf = self.get_nlf_cnf(x4, x3, x2, x1, x0)
                cnf_clauses.extend(nlf_cnf)
                
                # Feedback as native XOR: L[j] ^ k[i%64] ^ L[j-16] ^ L[j-32] ^ nlf_out = 0
                xor_clauses.append(([L[j], self.k[i % 64], L[j-16], L[j-32], nlf_out], False))
            
            # Final state = ciphertext
            for j in range(32):
                bit = (ct >> j) & 1
                state_idx = self.rounds + j
                cnf_clauses.append([L[state_idx] if bit else -L[state_idx]])
        
        return cnf_clauses, xor_clauses
    
    def extract_key_cryptominisat(self, model: tuple) -> int:
        """Extract key from CryptoMiniSat model (tuple of True/False/None)."""
        key = 0
        for i in range(64):
            var = self.k[i]
            if model[var]:  # True means variable is positive
                key |= (1 << i)
        return key
    
    def extract_key_pysat(self, model: List[int]) -> int:
        """Extract key from PySAT model (list of signed integers)."""
        key = 0
        model_set = set(model)
        for i in range(64):
            if self.k[i] in model_set:
                key |= (1 << i)
        return key


def solve_with_cryptominisat(encoder: KeeLoqSAT, plaintexts: List[int], 
                              ciphertexts: List[int], verbose: bool = True) -> Optional[int]:
    """Solve using CryptoMiniSat with native XOR clauses."""
    try:
        from pycryptosat import Solver
    except ImportError:
        print("ERROR: pycryptosat not installed. Run: pip install pycryptosat")
        return None
    
    if verbose:
        print("Building CryptoMiniSat instance with native XOR clauses...")
    
    cnf_clauses, xor_clauses = encoder.build_xor_clauses(plaintexts, ciphertexts)
    
    solver = Solver()
    
    # Add CNF clauses
    for clause in cnf_clauses:
        solver.add_clause(clause)
    
    # Add XOR clauses (native support!)
    for lits, rhs in xor_clauses:
        solver.add_xor_clause(lits, rhs)
    
    if verbose:
        print(f"CNF clauses: {len(cnf_clauses)}, XOR clauses: {len(xor_clauses)}")
        print("Solving...")
    
    start = time.time()
    sat, model = solver.solve()
    elapsed = time.time() - start
    
    if verbose:
        print(f"Solved in {elapsed:.3f}s")
    
    if sat:
        return encoder.extract_key_cryptominisat(model)
    return None


def solve_with_pysat(encoder: KeeLoqSAT, plaintexts: List[int], 
                     ciphertexts: List[int], solver_name: str = "cadical153",
                     verbose: bool = True) -> Optional[int]:
    """Solve using PySAT with specified solver."""
    try:
        from pysat.solvers import Solver
    except ImportError:
        print("ERROR: python-sat not installed. Run: pip install python-sat")
        return None
    
    if verbose:
        print(f"Building PySAT instance with {solver_name}...")
    
    clauses = encoder.build_cnf(plaintexts, ciphertexts)
    
    if verbose:
        print(f"Total clauses: {len(clauses)}, Variables: {encoder.next_var - 1}")
        print("Solving...")
    
    start = time.time()
    
    with Solver(name=solver_name, bootstrap_with=clauses) as solver:
        if solver.solve():
            model = solver.get_model()
            elapsed = time.time() - start
            if verbose:
                print(f"Solved in {elapsed:.3f}s")
            return encoder.extract_key_pysat(model)
        else:
            elapsed = time.time() - start
            if verbose:
                print(f"UNSAT in {elapsed:.3f}s")
    
    return None


def main():
    parser = argparse.ArgumentParser(
        description='KeeLoq SAT-based key recovery'
    )
    parser.add_argument(
        '--rounds', '-r', type=int, default=64,
        help='Number of rounds (default: 64)'
    )
    parser.add_argument(
        '--pairs', '-n', type=int, default=1,
        help='Number of P/C pairs (default: 1)'
    )
    parser.add_argument(
        '--solver', '-s', choices=['cryptominisat', 'cadical', 'glucose', 'minisat'],
        default='cryptominisat',
        help='SAT solver (default: cryptominisat)'
    )
    parser.add_argument(
        '--key', '-k', type=lambda x: int(x, 0), default=0x5CEC6701B79FD949,
        help='Secret key for verification'
    )
    
    args = parser.parse_args()
    
    # Generate test data
    import random
    random.seed(42)
    plaintexts = [random.randint(0, 0xFFFFFFFF) for _ in range(args.pairs)]
    ciphertexts = [keeloq_encrypt(args.key, pt, args.rounds) for pt in plaintexts]
    
    print("=" * 60)
    print("KeeLoq SAT-based Key Recovery")
    print("=" * 60)
    print(f"Rounds:     {args.rounds}")
    print(f"P/C pairs:  {args.pairs}")
    print(f"Solver:     {args.solver}")
    print(f"Target key: 0x{args.key:016X}")
    for i, (pt, ct) in enumerate(zip(plaintexts, ciphertexts)):
        print(f"  Pair {i}: P=0x{pt:08X} -> C=0x{ct:08X}")
    print("=" * 60)
    
    # Build encoder
    encoder = KeeLoqSAT(args.rounds, args.pairs)
    
    # Solve
    if args.solver == 'cryptominisat':
        key = solve_with_cryptominisat(encoder, plaintexts, ciphertexts)
    else:
        solver_map = {'cadical': 'cadical153', 'glucose': 'glucose4', 'minisat': 'minisat22'}
        key = solve_with_pysat(encoder, plaintexts, ciphertexts, solver_map[args.solver])
    
    print("\n" + "=" * 60)
    print(f"RESULT (solver: {args.solver})")
    print("=" * 60)
    if key is not None:
        print(f"RECOVERED KEY: 0x{key:016X}")
        
        # Verify: does this key produce the correct ciphertexts?
        all_match = True
        for pt, expected_ct in zip(plaintexts, ciphertexts):
            computed_ct = keeloq_encrypt(key, pt, args.rounds)
            if computed_ct != expected_ct:
                all_match = False
                break
        
        if all_match:
            print("VERIFIED: Recovered key produces correct ciphertexts!")
            if key == args.key:
                print("(Key matches target)")
            else:
                print("(Different from target - multiple valid keys exist)")
        else:
            print("ERROR: Recovered key does NOT produce correct ciphertexts!")
    else:
        print("FAILED: Could not recover key (UNSAT or solver error)")
    print("=" * 60)
    
    return key


if __name__ == '__main__':
    main()
