#!/usr/bin/env python3
"""
KeeLoq SAT-based Key Recovery

Uses SAT solvers to recover the secret key from plaintext-ciphertext pairs.
Supports CryptoMiniSat (native XOR) and PySAT (CaDiCaL, Glucose, etc.)

Requirements:
    pip install pycryptosat python-sat

Usage:
    python sat_solver.py [--rounds N] [--solver NAME] [--pairs N]
                         [--fixed-bits N] [--fixed-source MODE]
                         [--fixed-indices LIST] [--fixed-value 0x...]
                         [--guess-vars SPEC] [--guess-vars-file PATH]
                         [--verify-extra-pairs N] [--max-enum N]
                         [--enum-workers N] [--backbone] [--pairwise-affine]

Author: H. Hadipour
"""

import argparse
import multiprocessing
import random
import time
from typing import Optional, List, Tuple, Dict, Any

# KeeLoq NLF lookup constant
NLF_CONSTANT = 0x3A5C742E


# Shared counter for parallel progress reporting (set by cpu_parallel_enumerate)
_shared_counter = None
_shared_stop = None

# Shared objects for pairwise-affine worker pool
_pw_solver_name = None
_pw_clauses = None
_pw_key_vars = None


def _cpu_worker_init(counter, stop_flag):
    """Initializer for pool workers — stores shared objects."""
    global _shared_counter, _shared_stop
    _shared_counter = counter
    _shared_stop = stop_flag


def _pairwise_worker_init(solver_name: str, clauses: List[List[int]], key_vars: List[int]):
    """Initializer for pairwise-affine workers."""
    global _pw_solver_name, _pw_clauses, _pw_key_vars
    _pw_solver_name = solver_name
    _pw_clauses = clauses
    _pw_key_vars = key_vars


def _pair_pattern(solver, vi: int, vj: int) -> int:
    """Return 4-bit SAT pattern for (k_i, k_j) assignments in order 00,01,10,11."""
    sat00 = solver.solve(assumptions=[-vi, -vj])
    sat01 = solver.solve(assumptions=[-vi,  vj])
    sat10 = solver.solve(assumptions=[ vi, -vj])
    sat11 = solver.solve(assumptions=[ vi,  vj])
    return (1 if sat00 else 0) | ((1 if sat01 else 0) << 1) | ((1 if sat10 else 0) << 2) | ((1 if sat11 else 0) << 3)


def _pairwise_worker_scan(pair_chunk: List[Tuple[int, int]]) -> Dict[str, Any]:
    """Worker scan over a subset of key-index pairs; returns local relations."""
    try:
        from pysat.solvers import Solver as PySATSolver
    except ImportError:
        return {
            'xor_relations': [],
            'forced_bits': {},
            'contradiction': True,
            'processed': 0,
        }

    solver = PySATSolver(name=_pw_solver_name, bootstrap_with=_pw_clauses)
    try:
        xor_relations: List[Tuple[int, int, int]] = []
        forced_bits: Dict[int, int] = {}

        for i, j in pair_chunk:
            vi = _pw_key_vars[i]
            vj = _pw_key_vars[j]
            pat = _pair_pattern(solver, vi, vj)

            if pat == 0b1001:
                xor_relations.append((i, j, 0))
            elif pat == 0b0110:
                xor_relations.append((i, j, 1))
            elif pat in (0b0001, 0b0010, 0b0100, 0b1000):
                if pat == 0b0001:
                    bi, bj = 0, 0
                elif pat == 0b0010:
                    bi, bj = 0, 1
                elif pat == 0b0100:
                    bi, bj = 1, 0
                else:
                    bi, bj = 1, 1

                if i in forced_bits and forced_bits[i] != bi:
                    return {
                        'xor_relations': xor_relations,
                        'forced_bits': forced_bits,
                        'contradiction': True,
                        'processed': len(pair_chunk),
                    }
                if j in forced_bits and forced_bits[j] != bj:
                    return {
                        'xor_relations': xor_relations,
                        'forced_bits': forced_bits,
                        'contradiction': True,
                        'processed': len(pair_chunk),
                    }
                forced_bits[i] = bi
                forced_bits[j] = bj

        return {
            'xor_relations': xor_relations,
            'forced_bits': forced_bits,
            'contradiction': False,
            'processed': len(pair_chunk),
        }
    finally:
        solver.delete()


def _cpu_worker_enumerate(worker_args):
    """
    Worker function for CPU-parallel SAT enumeration.

    Each worker gets a partition of the key space (extra fixed bits) and
    enumerates solutions within that partition using blocking clauses.
    Returns a list of verified keys found.
    """
    (rounds, num_pairs, key_offsets, fixed_key_bits, guessed_var_bits,
     plaintexts, ciphertexts, solver_name, partition_bits, max_enum,
     verify_pts, verify_cts, is_slide528) = worker_args

    # Merge partition bits into fixed_key_bits
    merged_fixed = dict(fixed_key_bits)
    merged_fixed.update(partition_bits)

    encoder = KeeLoqSAT(
        rounds, num_pairs, key_offsets,
        fixed_key_bits=merged_fixed,
        guessed_var_bits=guessed_var_bits,
    )

    try:
        from pysat.solvers import Solver as PySATSolver
    except ImportError:
        return []

    clauses = encoder.build_cnf(plaintexts, ciphertexts)
    solver = PySATSolver(name=solver_name, bootstrap_with=clauses)

    found_keys = []
    for _ in range(max_enum):
        # Check early-termination flag
        if _shared_stop is not None and _shared_stop.value:
            break
        if not solver.solve():
            break
        key = encoder.extract_key_pysat(solver.get_model())

        # Bump shared progress counter
        if _shared_counter is not None:
            with _shared_counter.get_lock():
                _shared_counter.value += 1

        # Verify
        if is_slide528:
            P1 = plaintexts[0]
            P2 = ciphertexts[0]
            C1_computed = keeloq_encrypt(key, P1, 528)
            C2_computed = keeloq_encrypt(key, P2, 528)
            ok = (C1_computed == plaintexts[1] and C2_computed == ciphertexts[1])
        else:
            ok = verify_regular_key(key, plaintexts, ciphertexts, rounds)
            if ok and verify_pts:
                ok = verify_regular_key(key, verify_pts, verify_cts, rounds)

        if ok:
            found_keys.append(key)
            if _shared_stop is not None:
                _shared_stop.value = 1
            solver.delete()
            return found_keys

        # Add blocking clause and continue
        blocking = []
        for i in range(64):
            bit = (key >> i) & 1
            blocking.append(-encoder.k[i] if bit else encoder.k[i])
        solver.add_clause(blocking)

    solver.delete()
    return found_keys


def cpu_parallel_enumerate(args, encoder, first_key, plaintexts, ciphertexts,
                           key_offsets, fixed_key_bits, guessed_var_bits,
                           verify_plaintexts, verify_ciphertexts, verify_key_fn):
    """
    Partition the key space across workers and enumerate in parallel.

    Selects ceil(log2(workers)) unfixed key bits to partition on.
    Each worker independently runs SAT + blocking clause enumeration.
    """
    workers = args.enum_workers
    max_enum = args.max_enum

    # Determine partition bits: pick unfixed key bits to split on
    import math
    partition_width = max(1, math.ceil(math.log2(workers))) if workers > 1 else 0
    unfixed = [i for i in range(64) if i not in fixed_key_bits]
    # Use the first few unfixed bits for partitioning
    partition_indices = unfixed[:partition_width]
    num_partitions = 1 << len(partition_indices)

    if workers <= 1 or num_partitions <= 1:
        # Fall back to sequential enumeration
        return _sequential_enumerate(args, encoder, first_key, plaintexts, ciphertexts,
                                      verify_plaintexts, verify_ciphertexts, verify_key_fn)

    solver_map = {'cadical': 'cadical153', 'glucose': 'glucose4', 'minisat': 'minisat22',
                  'cryptominisat': 'cadical153'}  # CMS doesn't support incremental blocking
    solver_name = solver_map.get(args.solver, 'cadical153')

    # Build worker arguments for each partition
    worker_args_list = []
    per_worker_enum = max(1, max_enum // num_partitions)
    for part_id in range(num_partitions):
        partition_bits = {}
        for b, idx in enumerate(partition_indices):
            partition_bits[idx] = (part_id >> b) & 1
        worker_args_list.append((
            args.rounds, len(plaintexts), key_offsets, fixed_key_bits,
            guessed_var_bits, plaintexts, ciphertexts, solver_name,
            partition_bits, per_worker_enum,
            verify_plaintexts, verify_ciphertexts, args.slide528,
        ))

    total_budget = per_worker_enum * num_partitions
    print(f"Parallel CPU enumeration: {num_partitions} partitions across {workers} workers "
          f"(partitioning on key bits {partition_indices}, up to {total_budget} solutions total)")

    counter = multiprocessing.Value('i', 0)
    stop_flag = multiprocessing.Value('i', 0)
    t0 = time.time()
    last_printed = 0

    with multiprocessing.Pool(
        processes=min(workers, num_partitions),
        initializer=_cpu_worker_init,
        initargs=(counter, stop_flag),
    ) as pool:
        result_iter = pool.imap_unordered(_cpu_worker_enumerate, worker_args_list)
        # Poll for results with a short timeout to allow progress updates
        finished_partitions = 0
        while finished_partitions < num_partitions:
            try:
                result_keys = result_iter.next(timeout=0.5)
                finished_partitions += 1
                for k in result_keys:
                    elapsed = time.time() - t0
                    print(f"\r  Progress: {counter.value}/{total_budget} solutions tested "
                          f"[{elapsed:.1f}s] — VERIFIED key found!")
                    print(f"  Worker found verified key: 0x{k:016X}")
                    pool.terminate()
                    return k
            except multiprocessing.TimeoutError:
                pass
            # Print progress update if counter advanced
            current = counter.value
            if current > last_printed:
                elapsed = time.time() - t0
                rate = current / elapsed if elapsed > 0 else 0
                print(f"\r  Progress: {current}/{total_budget} solutions tested "
                      f"[{elapsed:.1f}s, {rate:.0f} sol/s]", end="", flush=True)
                last_printed = current

    elapsed = time.time() - t0
    print(f"\r  Progress: {counter.value}/{total_budget} solutions tested "
          f"[{elapsed:.1f}s] — exhausted all partitions")
    return None


def _sequential_enumerate(args, encoder, first_key, plaintexts, ciphertexts,
                          verify_plaintexts, verify_ciphertexts, verify_key_fn):
    """Original sequential blocking-clause enumeration (single process)."""
    from pysat.solvers import Solver as PySATSolver

    clauses = encoder.build_cnf(plaintexts, ciphertexts)
    # Block the first (failed) key
    blocking = []
    for i in range(64):
        bit = (first_key >> i) & 1
        blocking.append(-encoder.k[i] if bit else encoder.k[i])
    clauses.append(blocking)
    enum_solver = PySATSolver(name='cadical153', bootstrap_with=clauses)

    key = first_key
    last_attempt = 1
    for attempt in range(2, args.max_enum + 2):  # solution numbers starting from 2
        if not enum_solver.solve():
            break
        key = encoder.extract_key_pysat(enum_solver.get_model())
        last_attempt = attempt
        print(f"  Solution {attempt}: 0x{key:016X}", end="")

        ok = verify_key_fn(key)
        if ok and not args.slide528 and args.verify_extra_pairs > 0:
            ok = verify_regular_key(key, verify_plaintexts, verify_ciphertexts, args.rounds)

        if ok:
            print(" -> VERIFIED!")
            enum_solver.delete()
            return key
        else:
            print(" -> no match")

        # Block this key too
        blocking = []
        for i in range(64):
            bit = (key >> i) & 1
            blocking.append(-encoder.k[i] if bit else encoder.k[i])
        enum_solver.add_clause(blocking)

    enum_solver.delete()
    print(f"\nFAILED: No valid key found after {last_attempt} solutions")
    return None


def compute_backbone(solver, key_vars: list, verbose: bool = True) -> Dict[int, int]:
    """
    Identify key bits that are backbone members (forced by the SAT constraints).

    For each key bit i, we first read its value v from the current model
    (the last satisfying assignment stored in ``solver``), then probe whether
    the opposite polarity is consistent via ``solver.solve(assumptions=[...])``.

    * If UNSAT  →  bit i is forced to v in *every* solution  (backbone member).
    * If SAT    →  bit i is free; we adopt the new model progressively so later
                   probes can still benefit from an up-to-date working assignment.

    This is the "progressive backbone" strategy: as free-bit probes succeed we
    update the working assignment, which can only help (never hurt) subsequent
    probes.

    Args:
        solver:    A PySAT Solver instance that already has the CNF loaded and
                   whose last call was a satisfying ``solve()``.  The function
                   calls ``solver.solve(assumptions=[...])`` 64 times but does
                   NOT call ``solver.delete()`` — the caller remains responsible
                   for the solver's lifetime.
        key_vars:  List of 64 DIMACS variable indices for key bits k[0..63].
        verbose:   Print a progress line while probing.

    Returns:
        A dict ``{bit_index: forced_value}`` for every backbone key bit.
    """
    # Seed the working assignment from the current model
    model_set = set(solver.get_model())
    current_vals = {i: (1 if var in model_set else 0) for i, var in enumerate(key_vars)}

    backbone: Dict[int, int] = {}
    t0 = time.time()

    for i, var in enumerate(key_vars):
        v = current_vals[i]
        # Literal that contradicts the current value
        opposite_lit = -var if v else var

        if solver.solve(assumptions=[opposite_lit]):
            # SAT: bit i is free — update working assignment progressively
            new_model_set = set(solver.get_model())
            for j, jvar in enumerate(key_vars):
                current_vals[j] = 1 if jvar in new_model_set else 0
        else:
            # UNSAT: bit i is backbone-forced to v
            backbone[i] = v

        if verbose:
            elapsed = time.time() - t0
            forced = len(backbone)
            free = (i + 1) - forced
            print(
                f"\r  Backbone probe {i+1:2d}/64 — forced: {forced:2d}, free: {free:2d}"
                f"  [{elapsed:.1f}s]",
                end="", flush=True,
            )

    elapsed = time.time() - t0
    forced = len(backbone)
    if verbose:
        print(
            f"\r  Backbone: {forced}/64 bits forced, {64 - forced} free"
            f"  ({elapsed:.2f}s, 64 probes)   "
        )
    return backbone


def mine_pairwise_affine_relations(
    solver,
    key_vars: list,
    verbose: bool = True,
    workers: int = 1,
    solver_name: str = 'cadical153',
    clauses: Optional[List[List[int]]] = None,
) -> Dict[str, object]:
    """
    Mine exact pairwise affine relations over key bits using SAT assumptions.

    For each pair (i, j), probe satisfiability of all four assignments:
      (k_i, k_j) in {(0,0), (0,1), (1,0), (1,1)}.

    Useful outcomes:
      - SAT only on (00,11): k_i XOR k_j = 0
      - SAT only on (01,10): k_i XOR k_j = 1
      - SAT only on one assignment: both bits fixed by constraints

    Returns a dict with mined relations and a reduced-dimension estimate.
    """
    n = len(key_vars)
    if n != 64:
        raise ValueError(f"Expected 64 key vars, got {n}")

    # Pairwise XOR/equality relations: (i, j, rhs) meaning k_i XOR k_j = rhs
    xor_relations: List[Tuple[int, int, int]] = []
    # Bits forced by one-hot pair patterns discovered during probing
    forced_bits: Dict[int, int] = {}

    all_pairs = [(i, j) for i in range(n - 1) for j in range(i + 1, n)]
    total_pairs = len(all_pairs)
    scanned = 0
    t0 = time.time()

    if workers <= 1 or clauses is None:
        for i, j in all_pairs:
            vi = key_vars[i]
            vj = key_vars[j]
            pat = _pair_pattern(solver, vi, vj)

            if pat == 0b1001:
                xor_relations.append((i, j, 0))
            elif pat == 0b0110:
                xor_relations.append((i, j, 1))
            elif pat in (0b0001, 0b0010, 0b0100, 0b1000):
                if pat == 0b0001:
                    bi, bj = 0, 0
                elif pat == 0b0010:
                    bi, bj = 0, 1
                elif pat == 0b0100:
                    bi, bj = 1, 0
                else:
                    bi, bj = 1, 1

                if i in forced_bits and forced_bits[i] != bi:
                    return {
                        'xor_relations': xor_relations,
                        'forced_bits': forced_bits,
                        'contradiction': True,
                        'scan_time_s': time.time() - t0,
                        'pairs_scanned': scanned,
                        'total_pairs': total_pairs,
                        'dof': None,
                    }
                if j in forced_bits and forced_bits[j] != bj:
                    return {
                        'xor_relations': xor_relations,
                        'forced_bits': forced_bits,
                        'contradiction': True,
                        'scan_time_s': time.time() - t0,
                        'pairs_scanned': scanned,
                        'total_pairs': total_pairs,
                        'dof': None,
                    }
                forced_bits[i] = bi
                forced_bits[j] = bj

            scanned += 1
            if verbose and (scanned % 128 == 0 or scanned == total_pairs):
                elapsed = time.time() - t0
                print(
                    f"\r  Pairwise affine scan: {scanned}/{total_pairs} pairs"
                    f"  [{elapsed:.1f}s]",
                    end="", flush=True,
                )
    else:
        use_workers = min(max(1, workers), multiprocessing.cpu_count(), total_pairs)
        chunk_size = max(1, total_pairs // (use_workers * 8))
        chunks = [all_pairs[k:k + chunk_size] for k in range(0, total_pairs, chunk_size)]

        with multiprocessing.Pool(
            processes=use_workers,
            initializer=_pairwise_worker_init,
            initargs=(solver_name, clauses, key_vars),
        ) as pool:
            for out in pool.imap_unordered(_pairwise_worker_scan, chunks):
                scanned += out.get('processed', 0)
                if out.get('contradiction', False):
                    pool.terminate()
                    return {
                        'xor_relations': xor_relations,
                        'forced_bits': forced_bits,
                        'contradiction': True,
                        'scan_time_s': time.time() - t0,
                        'pairs_scanned': scanned,
                        'total_pairs': total_pairs,
                        'dof': None,
                    }

                xor_relations.extend(out.get('xor_relations', []))
                out_forced = out.get('forced_bits', {})
                for idx, val in out_forced.items():
                    if idx in forced_bits and forced_bits[idx] != val:
                        pool.terminate()
                        return {
                            'xor_relations': xor_relations,
                            'forced_bits': forced_bits,
                            'contradiction': True,
                            'scan_time_s': time.time() - t0,
                            'pairs_scanned': scanned,
                            'total_pairs': total_pairs,
                            'dof': None,
                        }
                    forced_bits[idx] = val

                if verbose:
                    elapsed = time.time() - t0
                    print(
                        f"\r  Pairwise affine scan: {scanned}/{total_pairs} pairs"
                        f"  [{elapsed:.1f}s]",
                        end="", flush=True,
                    )

    # Union-find with parity to estimate key-space dimension under mined affine constraints.
    parent = list(range(n))
    rank = [0] * n
    parity = [0] * n  # parity[x] = x XOR parent[x]

    def find(x: int) -> Tuple[int, int]:
        if parent[x] == x:
            return x, 0
        r, p = find(parent[x])
        parity[x] ^= p
        parent[x] = r
        return parent[x], parity[x]

    def union(x: int, y: int, rhs: int) -> bool:
        rx, px = find(x)
        ry, py = find(y)
        if rx == ry:
            return (px ^ py) == rhs
        if rank[rx] < rank[ry]:
            rx, ry = ry, rx
            px, py = py, px
        parent[ry] = rx
        # Need: (px) XOR parity[ry] XOR (py) = rhs  => parity[ry] = px XOR py XOR rhs
        parity[ry] = px ^ py ^ rhs
        if rank[rx] == rank[ry]:
            rank[rx] += 1
        return True

    contradiction = False
    for i, j, rhs in xor_relations:
        if not union(i, j, rhs):
            contradiction = True
            break

    root_fixed: Dict[int, int] = {}
    if not contradiction:
        for bit_idx, bit_val in forced_bits.items():
            r, p = find(bit_idx)
            # bit = root XOR p  => root = bit XOR p
            root_val = bit_val ^ p
            prev = root_fixed.get(r)
            if prev is not None and prev != root_val:
                contradiction = True
                break
            root_fixed[r] = root_val

    dof = None
    if not contradiction:
        roots = {find(i)[0] for i in range(n)}
        dof = sum(1 for r in roots if r not in root_fixed)

    elapsed = time.time() - t0
    if verbose:
        print(f"\r  Pairwise affine scan: {total_pairs}/{total_pairs} pairs  [{elapsed:.1f}s]   ")

    return {
        'xor_relations': xor_relations,
        'forced_bits': forced_bits,
        'contradiction': contradiction,
        'scan_time_s': elapsed,
        'pairs_scanned': scanned,
        'total_pairs': total_pairs,
        'dof': dof,
    }


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
    
    def __init__(self, rounds: int, num_pairs: int = 1, key_offsets: List[int] = None,
                 fixed_key_bits: Optional[Dict[int, int]] = None,
                 guessed_var_bits: Optional[Dict[str, int]] = None):
        self.rounds = rounds
        self.num_pairs = num_pairs
        self.num_state = 32 + rounds
        # key_offsets[p] = starting key index for constraint p (default: all 0)
        self.key_offsets = key_offsets if key_offsets else [0] * num_pairs
        self.fixed_key_bits = fixed_key_bits if fixed_key_bits else {}
        self.guessed_var_bits = guessed_var_bits if guessed_var_bits else {}
        
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

    def get_fixed_key_clauses(self) -> List[List[int]]:
        """Return unit clauses fixing selected key bits."""
        clauses = []
        for bit_idx, bit_value in sorted(self.fixed_key_bits.items()):
            key_var = self.k[bit_idx]
            clauses.append([key_var] if bit_value else [-key_var])
        return clauses

    def get_guessed_var_clauses(self) -> List[List[int]]:
        """Return clauses fixing guessed key/state/auxiliary variables."""
        clauses = []
        for name, bit_value in sorted(self.guessed_var_bits.items(), key=lambda item: guess_variable_sort_key(item[0])):
            parts = name.split('_')
            prefix = parts[0]
            if prefix == 'k':
                var = self.k[int(parts[1])]
                clauses.append([var] if bit_value else [-var])
                continue

            pair_idx = int(parts[1])
            round_idx = int(parts[2])
            if prefix == 'L':
                var = self.L[pair_idx][round_idx]
                clauses.append([var] if bit_value else [-var])
            elif prefix == 'a':
                left = self.L[pair_idx][round_idx - 1]
                right = self.L[pair_idx][round_idx - 6]
                if bit_value:
                    clauses.extend([[left], [right]])
                else:
                    clauses.append([-left, -right])
            elif prefix == 'b':
                left = self.L[pair_idx][round_idx - 1]
                right = self.L[pair_idx][round_idx - 31]
                if bit_value:
                    clauses.extend([[left], [right]])
                else:
                    clauses.append([-left, -right])
            else:
                raise ValueError(f"Unsupported guessed variable '{name}'")
        return clauses
        
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
        # Reset auxiliary variable cache so repeated calls produce valid clause sets
        self.aux_vars = {}
        clauses = self.get_fixed_key_clauses()
        clauses.extend(self.get_guessed_var_clauses())
        
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
                
                # Feedback: L[j] = k[(i+offset)%64] ^ L[j-16] ^ L[j-32] ^ nlf_out
                # Rearrange: L[j] ^ k[(i+offset)%64] ^ L[j-16] ^ L[j-32] ^ nlf_out = 0
                key_idx = (i + self.key_offsets[p]) % 64
                lits = [L[j], self.k[key_idx], L[j-16], L[j-32], nlf_out]
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
        # Reset auxiliary variable cache so repeated calls produce valid clause sets
        self.aux_vars = {}
        cnf_clauses = self.get_fixed_key_clauses()
        cnf_clauses.extend(self.get_guessed_var_clauses())
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
                
                # Feedback as native XOR: L[j] ^ k[(i+offset)%64] ^ L[j-16] ^ L[j-32] ^ nlf_out = 0
                key_idx = (i + self.key_offsets[p]) % 64
                xor_clauses.append(([L[j], self.k[key_idx], L[j-16], L[j-32], nlf_out], False))
            
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
        import sys
        print(f"ERROR: pycryptosat not found for {sys.executable}")
        print(f"  Run: {sys.executable} -m pip install pycryptosat")
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
    """Solve using PySAT with specified solver. Returns (key, solver_instance) or (None, None)."""
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
    
    solver = Solver(name=solver_name, bootstrap_with=clauses)
    if solver.solve():
        model = solver.get_model()
        elapsed = time.time() - start
        if verbose:
            print(f"Solved in {elapsed:.3f}s")
        key = encoder.extract_key_pysat(model)
        return key, solver
    else:
        elapsed = time.time() - start
        if verbose:
            print(f"UNSAT in {elapsed:.3f}s")
        solver.delete()
        return None, None


def resolve_fixed_key_bits(args: argparse.Namespace) -> Tuple[Dict[int, int], Optional[int], str]:
    """Resolve fixed key bits from CLI arguments."""
    selected_bits = parse_bit_indices(args.fixed_indices) if args.fixed_indices else list(range(args.fixed_bits))
    if not selected_bits or args.fixed_source == 'unknown':
        return {}, None, 'all key bits unknown'

    if args.fixed_source == 'correct':
        source_key = args.key
        description = 'true target key'
    elif args.fixed_source == 'random':
        source_key = random.SystemRandom().getrandbits(64)
        description = 'random 64-bit value'
    else:
        if args.fixed_value is None:
            raise ValueError('--fixed-value is required when --fixed-source=user')
        source_key = args.fixed_value
        description = 'user-supplied 64-bit value'

    fixed_key_bits = {
        bit_idx: (source_key >> bit_idx) & 1
        for bit_idx in selected_bits
    }
    return fixed_key_bits, source_key, description


def tokenize_guess_spec(text: str) -> List[str]:
    """Split comma/whitespace-separated guess specs into tokens."""
    return [token for token in text.replace(',', ' ').split() if token]


def read_guess_spec_file(path: str) -> List[str]:
    """Read guess specs from a text file, supporting comments and comma/space separators."""
    tokens: List[str] = []
    with open(path, 'r', encoding='utf-8') as handle:
        for _line_no, raw_line in enumerate(handle, start=1):
            content = raw_line.split('#', 1)[0].strip()
            if not content:
                continue
            line_tokens = tokenize_guess_spec(content)
            if not line_tokens:
                continue
            tokens.extend(line_tokens)
    return tokens


def parse_guess_token(token: str) -> Tuple[str, Optional[int]]:
    """Parse NAME or NAME=BIT guessed-variable tokens."""
    if token.count('=') > 1:
        raise ValueError(f"Invalid guessed-variable token '{token}'")
    if '=' not in token:
        return token.strip(), None

    name, bit_text = token.split('=', 1)
    name = name.strip()
    bit_text = bit_text.strip()
    if bit_text not in {'0', '1'}:
        raise ValueError(f"Guessed-variable assignment must end in =0 or =1: '{token}'")
    return name, int(bit_text)


def validate_guess_variable_name(name: str, rounds: int, num_pairs: int) -> None:
    """Validate supported guessed-variable names."""
    parts = name.split('_')
    prefix = parts[0]
    if prefix == 'k' and len(parts) == 2:
        bit_idx = int(parts[1], 10)
        if not 0 <= bit_idx <= 63:
            raise ValueError(f"Key variable '{name}' is out of range")
        return

    if prefix in {'L', 'a', 'b'} and len(parts) == 3:
        pair_idx = int(parts[1], 10)
        round_idx = int(parts[2], 10)
        if not 0 <= pair_idx < num_pairs:
            raise ValueError(f"Variable '{name}' uses pair index outside 0..{num_pairs - 1}")
        if prefix == 'L':
            if not 0 <= round_idx < rounds + 32:
                raise ValueError(f"State variable '{name}' is out of range for {rounds} rounds")
            return
        if not 32 <= round_idx < rounds + 32:
            raise ValueError(f"Auxiliary variable '{name}' is out of range for {rounds} rounds")
        return

    raise ValueError(
        f"Unsupported guessed variable '{name}'. Expected k_i, L_p_r, a_p_r, or b_p_r"
    )


def guess_variable_sort_key(name: str) -> Tuple[int, int, int]:
    """Stable sort key for guessed variables."""
    parts = name.split('_')
    prefix_order = {'k': 0, 'L': 1, 'a': 2, 'b': 3}
    prefix = prefix_order.get(parts[0], 99)
    if parts[0] == 'k':
        return (prefix, int(parts[1]), -1)
    return (prefix, int(parts[1]), int(parts[2]))


def summarize_guessed_variables(variable_bits: Dict[str, int]) -> str:
    """Compact textual summary of guessed variables."""
    if not variable_bits:
        return 'none'
    names = sorted(variable_bits.keys(), key=guess_variable_sort_key)
    if len(names) <= 8:
        return ', '.join(f"{name}={variable_bits[name]}" for name in names)
    preview = ', '.join(f"{name}={variable_bits[name]}" for name in names[:8])
    return f"{preview}, ... ({len(names)} total)"


def build_true_variable_assignments(key: int, plaintexts: List[int], rounds: int) -> Dict[str, int]:
    """Build true values for key, state, and algebraic auxiliary variables."""
    assignments = {f"k_{idx}": (key >> idx) & 1 for idx in range(64)}
    for pair_idx, pt in enumerate(plaintexts):
        values: Dict[int, int] = {}
        for j in range(32):
            bit = (pt >> j) & 1
            values[j] = bit
            assignments[f"L_{pair_idx}_{j}"] = bit
        for j in range(32, rounds + 32):
            a_val = values[j - 1] & values[j - 6]
            b_val = values[j - 1] & values[j - 31]
            l_val = (
                assignments[f"k_{(j - 32) % 64}"]
                ^ values[j - 32]
                ^ values[j - 16]
                ^ values[j - 23]
                ^ values[j - 31]
                ^ (values[j - 1] & values[j - 12])
                ^ b_val
                ^ (values[j - 6] & values[j - 12])
                ^ (values[j - 6] & values[j - 31])
                ^ (values[j - 12] & values[j - 23])
                ^ (values[j - 23] & values[j - 31])
                ^ (b_val & values[j - 23])
                ^ (b_val & values[j - 12])
                ^ (a_val & values[j - 23])
                ^ (a_val & values[j - 12])
            )
            values[j] = l_val
            assignments[f"a_{pair_idx}_{j}"] = a_val
            assignments[f"b_{pair_idx}_{j}"] = b_val
            assignments[f"L_{pair_idx}_{j}"] = l_val
    return assignments


def resolve_guessed_variable_bits(
    args: argparse.Namespace,
    plaintexts: List[int],
    rounds: int,
    num_pairs: int,
    target_key: int,
    fixed_key_bits: Dict[int, int],
) -> Tuple[List[str], Dict[str, int], str]:
    """Resolve guessed variable assignments from CLI and/or text file."""
    tokens: List[str] = []
    if args.guess_vars:
        tokens.extend(tokenize_guess_spec(args.guess_vars))
    if args.guess_vars_file:
        tokens.extend(read_guess_spec_file(args.guess_vars_file))
    if not tokens:
        return [], {}, 'no guessed variables selected'

    parsed_tokens: List[Tuple[str, Optional[int]]] = []
    for token in tokens:
        name, explicit_bit = parse_guess_token(token)
        validate_guess_variable_name(name, rounds, num_pairs)
        parsed_tokens.append((name, explicit_bit))

    selected_names = sorted({name for name, _ in parsed_tokens}, key=guess_variable_sort_key)

    if args.guess_source == 'correct':
        true_assignments = build_true_variable_assignments(target_key, plaintexts, rounds)
        random_assignments: Dict[str, int] = {}
        description = 'true target-instance values'
    elif args.guess_source == 'random':
        true_assignments = {}
        random_rng = random.SystemRandom()
        random_assignments = {}
        for name, explicit_bit in parsed_tokens:
            if explicit_bit is None and name not in random_assignments:
                random_assignments[name] = random_rng.randint(0, 1)
        description = 'random guessed-variable values'
    else:
        true_assignments = {}
        random_assignments = {}
        description = 'unknown guessed-variable values'

    resolved: Dict[str, int] = {}
    for name, explicit_bit in parsed_tokens:
        if explicit_bit is not None:
            bit_value = explicit_bit
        elif args.guess_source == 'correct':
            bit_value = true_assignments[name]
        elif args.guess_source == 'random':
            bit_value = random_assignments[name]
        else:
            continue
        if name in resolved and resolved[name] != bit_value:
            raise ValueError(f"Conflicting guessed-variable assignments for '{name}'")
        resolved[name] = bit_value

    for name, bit_value in resolved.items():
        if not name.startswith('k_'):
            continue
        key_idx = int(name.split('_')[1], 10)
        existing = fixed_key_bits.get(key_idx)
        if existing is not None and existing != bit_value:
            raise ValueError(
                f"Guessed variable '{name}={bit_value}' conflicts with fixed key bit k_{key_idx}={existing}"
            )
    return selected_names, dict(sorted(resolved.items(), key=lambda item: guess_variable_sort_key(item[0]))), description


def parse_bit_indices(spec: str) -> List[int]:
    """Parse comma-separated bit indices/ranges like '0-15,48-63'."""
    selected = set()
    for part in spec.split(','):
        token = part.strip()
        if not token:
            continue
        if '-' in token:
            bounds = token.split('-', 1)
            if len(bounds) != 2 or not bounds[0].strip() or not bounds[1].strip():
                raise ValueError(f"Invalid bit range '{token}'")
            start = int(bounds[0], 10)
            end = int(bounds[1], 10)
            if start > end:
                raise ValueError(f"Invalid descending bit range '{token}'")
            for bit_idx in range(start, end + 1):
                if not 0 <= bit_idx <= 63:
                    raise ValueError(f"Bit index {bit_idx} out of range 0..63")
                selected.add(bit_idx)
        else:
            bit_idx = int(token, 10)
            if not 0 <= bit_idx <= 63:
                raise ValueError(f"Bit index {bit_idx} out of range 0..63")
            selected.add(bit_idx)
    return sorted(selected)


def summarize_bit_indices(bit_indices: List[int]) -> str:
    """Compact textual summary of selected bit indices."""
    if not bit_indices:
        return 'none'

    ranges = []
    start = prev = bit_indices[0]
    for bit_idx in bit_indices[1:]:
        if bit_idx == prev + 1:
            prev = bit_idx
            continue
        ranges.append(f"{start}-{prev}" if start != prev else str(start))
        start = prev = bit_idx
    ranges.append(f"{start}-{prev}" if start != prev else str(start))
    return ','.join(ranges)


def estimate_remaining_key_space(num_pairs: int, fixed_bits: int) -> int:
    """Heuristic exponent for the remaining number of keys: about 2^(64 - fixed_bits - 32*num_pairs)."""
    return 64 - fixed_bits - 32 * num_pairs


def format_key_space_estimate(num_pairs: int, fixed_bits: int) -> str:
    """Human-readable ambiguity estimate for random-looking reduced-round instances."""
    exponent = estimate_remaining_key_space(num_pairs, fixed_bits)
    if exponent > 0:
        return f"heuristic residual key space: about 2^{exponent} candidates"
    if exponent == 0:
        return "heuristic residual key space: about 2^0 = 1 candidate on average"
    return f"heuristically overdetermined by {-exponent} bits"


def verify_regular_key(key: int, plaintexts: List[int], ciphertexts: List[int], rounds: int) -> bool:
    """Check whether a key reproduces a list of reduced-round P/C pairs."""
    for pt, expected_ct in zip(plaintexts, ciphertexts):
        if keeloq_encrypt(key, pt, rounds) != expected_ct:
            return False
    return True


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
    parser.add_argument(
        '--slide528', action='store_true',
        help='Slide528 mode: two 64-round constraints with key offsets 0 and 16'
    )
    parser.add_argument(
        '--fixed-bits', type=int, default=0,
        help='Fix the lowest N key bits k[0..N-1] as SAT unit clauses (default: 0, all key bits unknown)'
    )
    parser.add_argument(
        '--fixed-indices', type=str,
        help='Fix exactly these key bit positions, e.g. 0-15,48-63; overrides --fixed-bits when provided'
    )
    parser.add_argument(
        '--fixed-source', choices=['unknown', 'correct', 'random', 'user'], default='unknown',
        help='How fixed key bits are chosen: unknown, correct target key, random 64-bit value, or user value (default: unknown)'
    )
    parser.add_argument(
        '--fixed-value', type=lambda x: int(x, 0),
        help='64-bit value used when --fixed-source=user'
    )
    parser.add_argument(
        '--guess-vars', type=str,
        help='Comma/space-separated guessed variables such as "k_19,b_0_67,L_1_80"; bare names are assigned according to --guess-source, NAME=0/1 overrides them'
    )
    parser.add_argument(
        '--guess-vars-file', type=str,
        help='Text file containing guessed variables, one or more per line, with optional comments starting with #'
    )
    parser.add_argument(
        '--guess-source', choices=['unknown', 'correct', 'random'], default='unknown',
        help='How bare guessed-variable names are valued: leave unknown, use true target-instance values, or use random bits (default: unknown)'
    )
    parser.add_argument(
        '--verify-extra-pairs', type=int, default=4,
        help='Number of extra holdout P/C pairs used only for post-solve verification in regular mode (default: 4)'
    )
    parser.add_argument(
        '--max-enum', type=int, default=100,
        help='Maximum number of SAT solutions to enumerate when the first solution fails verification. '
             'Set to 0 to disable enumeration and stop after the first solution. (default: 100)'
    )
    parser.add_argument(
        '--enum-workers', '-w', type=int, default=1,
        help='Number of parallel workers for CPU enumeration. '
             '1 = sequential blocking clauses; >1 = partitioned parallel SAT. (default: 1)'
    )
    parser.add_argument(
        '--backbone', action='store_true',
        help='Before enumeration, use SAT backbone analysis to discover which key bits are '
             'uniquely forced by the given constraints, then enumerate only the remaining '
             'free bits.  Works with pysat-based solvers (cadical, glucose, minisat). '
             'Especially useful with very few P/C pairs where the system is underdetermined '
             'and --fixed-bits is not available.  Adds 64 SAT probes but can drastically '
             'reduce the enumeration search space.'
    )
    parser.add_argument(
        '--pairwise-affine', action='store_true',
        help='Mine exact pairwise key-bit affine relations from SAT assumptions '
             '(k_i XOR k_j = c). Useful when single-bit backbone is empty: '
             'relations can still reduce brute-force dimension even if no key bit is '
             'individually forced.'
    )
    parser.add_argument(
        '--pairwise-workers', type=int, default=1,
        help='Number of worker processes for pairwise-affine mining. '
             '1 = sequential scan on the live solver; >1 = process-parallel scan '
             'where each worker builds its own SAT solver on the same CNF. '
             '(default: 1)'
    )
    
    args = parser.parse_args()

    if not 0 <= args.fixed_bits <= 64:
        parser.error('--fixed-bits must be between 0 and 64')
    try:
        explicit_fixed_indices = parse_bit_indices(args.fixed_indices) if args.fixed_indices else None
    except ValueError as exc:
        parser.error(str(exc))
    if args.fixed_source == 'user' and args.fixed_value is None:
        parser.error('--fixed-value is required when --fixed-source=user')
    if args.fixed_source != 'user' and args.fixed_value is not None:
        parser.error('--fixed-value can only be used with --fixed-source=user')
    if args.verify_extra_pairs < 0:
        parser.error('--verify-extra-pairs must be non-negative')
    if args.pairwise_workers < 1:
        parser.error('--pairwise-workers must be >= 1')
    selected_fixed_indices = explicit_fixed_indices if explicit_fixed_indices is not None else list(range(args.fixed_bits))
    
    # Generate test data
    data_rng = random.Random(42)
    fixed_key_bits, fixed_source_key, fixed_description = resolve_fixed_key_bits(args)
    
    if args.slide528:
        # Slide528 mode: generate a slid pair
        args.rounds = 64  # Force 64 rounds per constraint
        P1 = data_rng.randint(0, 0xFFFFFFFF)
        P2 = keeloq_encrypt(args.key, P1, 64)   # P2 = E_64(K, P1)
        C1 = keeloq_encrypt(args.key, P1, 528)   # C1 = E_528(K, P1)
        C2 = keeloq_encrypt(args.key, P2, 528)   # C2 = E_528(K, P2)
        
        # Constraint 0: E_64(K, P1) = P2 with key offset 0
        # Constraint 1: E'_64(K, C1) = C2 with key offset 16
        plaintexts = [P1, C1]
        ciphertexts = [P2, C2]
        key_offsets = [0, 16]
        
        print("=" * 60)
        print("KeeLoq SAT-based Key Recovery (Slide528 Mode)")
        print("=" * 60)
        print(f"Solver:     {args.solver}")
        print(f"Target key: 0x{args.key:016X}")
        print(f"Fixed bits: {len(selected_fixed_indices)} ({fixed_description})")
        print(f"  Indices:  {summarize_bit_indices(selected_fixed_indices)}")
        print(f"Heuristic:  {format_key_space_estimate(len(plaintexts), len(selected_fixed_indices))}")
        if fixed_source_key is not None:
            print(f"  Fixed-bit source value: 0x{fixed_source_key:016X}")
        print(f"  P1=0x{P1:08X}, P2=0x{P2:08X} (E_64, key offset 0)")
        print(f"  C1=0x{C1:08X}, C2=0x{C2:08X} (E'_64, key offset 16)")
        print("=" * 60)
    else:
        plaintexts = [data_rng.randint(0, 0xFFFFFFFF) for _ in range(args.pairs)]
        ciphertexts = [keeloq_encrypt(args.key, pt, args.rounds) for pt in plaintexts]
        verify_plaintexts = [data_rng.randint(0, 0xFFFFFFFF) for _ in range(args.verify_extra_pairs)]
        verify_ciphertexts = [keeloq_encrypt(args.key, pt, args.rounds) for pt in verify_plaintexts]
        key_offsets = None
        
        print("=" * 60)
        print("KeeLoq SAT-based Key Recovery")
        print("=" * 60)
        print(f"Rounds:     {args.rounds}")
        print(f"P/C pairs:  {args.pairs}")
        print(f"Solver:     {args.solver}")
        print(f"Target key: 0x{args.key:016X}")
        print(f"Fixed bits: {len(selected_fixed_indices)} ({fixed_description})")
        print(f"  Indices:  {summarize_bit_indices(selected_fixed_indices)}")
        print(f"Heuristic:  {format_key_space_estimate(args.pairs, len(selected_fixed_indices))}")
        print(f"Holdout:    {args.verify_extra_pairs} extra verification pair(s)")
        if fixed_source_key is not None:
            print(f"  Fixed-bit source value: 0x{fixed_source_key:016X}")
        for i, (pt, ct) in enumerate(zip(plaintexts, ciphertexts)):
            print(f"  Pair {i}: P=0x{pt:08X} -> C=0x{ct:08X}")
        print("=" * 60)

    try:
        guessed_var_names, guessed_var_bits, guessed_var_description = resolve_guessed_variable_bits(
            args,
            plaintexts,
            args.rounds,
            len(plaintexts),
            args.key,
            fixed_key_bits,
        )
    except (OSError, ValueError) as exc:
        parser.error(str(exc))

    if args.guess_vars or args.guess_vars_file:
        print(f"Guess source: {args.guess_source} ({guessed_var_description})")
        print(f"Guess set size: {len(guessed_var_names)}")
        if guessed_var_names:
            if len(guessed_var_names) <= 8:
                preview = ', '.join(guessed_var_names)
            else:
                preview = ', '.join(guessed_var_names[:8]) + f", ... ({len(guessed_var_names)} total)"
            print(f"  Names:    {preview}")
        print(f"Guessed vars fixed: {len(guessed_var_bits)}")
        if guessed_var_bits:
            print(f"  Values:   {summarize_guessed_variables(guessed_var_bits)}")
        print("=" * 60)
    
    # Build encoder
    num_pairs = len(plaintexts)
    encoder = KeeLoqSAT(
        args.rounds,
        num_pairs,
        key_offsets,
        fixed_key_bits=fixed_key_bits,
        guessed_var_bits=guessed_var_bits,
    )
    
    # Solve
    if args.solver == 'cryptominisat':
        key = solve_with_cryptominisat(encoder, plaintexts, ciphertexts)
        pysat_solver = None
    else:
        solver_map = {'cadical': 'cadical153', 'glucose': 'glucose4', 'minisat': 'minisat22'}
        key, pysat_solver = solve_with_pysat(encoder, plaintexts, ciphertexts, solver_map[args.solver])
    
    print("\n" + "=" * 60)
    print(f"RESULT (solver: {args.solver})")
    print("=" * 60)
    
    def verify_key(k):
        """Primary verification used by the solver output."""
        if args.slide528:
            P1_orig = plaintexts[0]
            P2_orig = ciphertexts[0]
            C1_computed = keeloq_encrypt(k, P1_orig, 528)
            C2_computed = keeloq_encrypt(k, P2_orig, 528)
            return C1_computed == plaintexts[1] and C2_computed == ciphertexts[1]
        return verify_regular_key(k, plaintexts, ciphertexts, args.rounds)
    
    if key is not None:
        print(f"Candidate key (solution 1): 0x{key:016X}")

        if args.pairwise_affine and pysat_solver is not None and not args.slide528:
            print("Mining pairwise affine key relations (2016 pairs, exact SAT probes)...")
            pairwise_solver_map = {'cadical': 'cadical153', 'glucose': 'glucose4', 'minisat': 'minisat22'}
            pairwise_solver_name = pairwise_solver_map.get(args.solver, 'cadical153')
            pairwise_clauses = None
            if args.pairwise_workers > 1:
                # Parallel mode needs independent solver instances in workers.
                pairwise_clauses = encoder.build_cnf(plaintexts, ciphertexts)
                print(f"  Pairwise workers: {args.pairwise_workers} (process-parallel)")
            rel = mine_pairwise_affine_relations(
                pysat_solver,
                encoder.k,
                verbose=True,
                workers=args.pairwise_workers,
                solver_name=pairwise_solver_name,
                clauses=pairwise_clauses,
            )
            if rel['contradiction']:
                print("  Pairwise analysis found an internal contradiction (unexpected).")
            else:
                xr = rel['xor_relations']
                fb = rel['forced_bits']
                dof = rel['dof']
                print(
                    f"  Pairwise affine result: {len(xr)} XOR relations, {len(fb)} forced bits, "
                    f"dimension <= {dof} (from 64)"
                )
                if xr:
                    preview_n = min(12, len(xr))
                    print("  Relation preview:")
                    for i, j, rhs in xr[:preview_n]:
                        print(f"    k_{i} XOR k_{j} = {rhs}")
                    if len(xr) > preview_n:
                        print(f"    ... ({len(xr) - preview_n} more)")
                if fb:
                    preview_bits = sorted(fb.items())[:12]
                    vals = ', '.join(f"k_{i}={v}" for i, v in preview_bits)
                    suffix = "" if len(fb) <= 12 else f", ... ({len(fb)} total)"
                    print(f"  Forced-bit preview: {vals}{suffix}")
                if dof is not None:
                    print(f"  Estimated brute-force space under these affine constraints: 2^{dof}")

        # Determine whether this first candidate is fully verified
        if args.slide528:
            first_ok = verify_key(key)
            if first_ok:
                print("VERIFIED: Candidate satisfies the full 528-round slide528 check.")
                if key == args.key:
                    print("(Key matches target)")
        else:
            satisfies_input = verify_key(key)
            holdout_ok = False
            if satisfies_input:
                print(f"SATISFIES INPUT PAIRS: candidate reproduces the {args.pairs} solving pair(s).")
                if args.verify_extra_pairs > 0:
                    holdout_ok = verify_regular_key(key, verify_plaintexts, verify_ciphertexts, args.rounds)
                    if holdout_ok:
                        print(f"HOLDOUT VERIFIED: candidate also matches {args.verify_extra_pairs} extra pair(s).")
                    else:
                        print(f"HOLDOUT FAILED: candidate does not match the {args.verify_extra_pairs} extra verification pair(s).")
                else:
                    holdout_ok = True  # no holdout requested
            else:
                print("WARNING: Recovered key does NOT reproduce the solving pairs.")
            first_ok = satisfies_input and holdout_ok
            if first_ok:
                if key == args.key:
                    print("(Key matches target)")
                else:
                    print("(Key differs from target; the current constraints do not uniquely identify the full 64-bit key.)")

        # If the first solution was not fully verified, enumerate more solutions
        if not first_ok and args.max_enum > 0:
            print(f"Enumerating other solutions (max {args.max_enum}, CPU blocking-clause path)...")
            recovered = None

            # --backbone: probe the live solver to discover which key bits are
            # uniquely forced by the constraints, without exploiting --fixed-bits.
            enum_fixed_bits = fixed_key_bits  # default: only CLI-specified fixed bits
            enum_encoder = encoder
            if getattr(args, 'backbone', False) and pysat_solver is not None and not args.slide528:
                print("Computing SAT backbone (64 assumption probes)...")
                backbone_bits = compute_backbone(pysat_solver, encoder.k, verbose=True)
                # Merge: backbone discoveries take priority; CLI fixed bits are kept too
                enum_fixed_bits = {**backbone_bits, **fixed_key_bits}
                free_count = 64 - len(enum_fixed_bits)
                print(
                    f"  Backbone result: {len(backbone_bits)} bits forced by constraints, "
                    f"{len(fixed_key_bits)} bits fixed via --fixed-bits, "
                    f"{free_count} bits free for enumeration"
                )
                if free_count == 0:
                    print("  All key bits determined — no enumeration needed.")
                    enum_fixed_bits_key = sum(v << i for i, v in enum_fixed_bits.items())
                    print(f"  Determined key: 0x{enum_fixed_bits_key:016X}")
                    if verify_key(enum_fixed_bits_key):
                        recovered = enum_fixed_bits_key
                    print("=" * 60)
                    if recovered is not None:
                        key = recovered
                        print(f"\nRECOVERED KEY: 0x{key:016X}")
                        if key == args.key:
                            print("(Key matches target)")
                    else:
                        print("\nFAILED: Backbone-determined key failed verification.")
                    if pysat_solver is not None:
                        pysat_solver.delete()
                    print("=" * 60)
                    return key
                # Rebuild encoder with the effective fixed bits for CPU paths
                enum_encoder = KeeLoqSAT(
                    args.rounds, num_pairs, key_offsets,
                    fixed_key_bits=enum_fixed_bits,
                    guessed_var_bits=guessed_var_bits,
                )

            recovered = cpu_parallel_enumerate(
                args, enum_encoder, key, plaintexts, ciphertexts,
                key_offsets, enum_fixed_bits, guessed_var_bits,
                verify_plaintexts, verify_ciphertexts, verify_key)

            if recovered is not None:
                key = recovered
                print(f"\nRECOVERED KEY: 0x{key:016X}")
                if key == args.key:
                    print("(Key matches target)")
            else:
                print(f"\nFAILED: No valid key found during enumeration")
        elif not first_ok:
            print("Enumeration disabled (--max-enum 0). First solution did not verify.")
    else:
        print("FAILED: Could not recover key (UNSAT or solver error)")
    
    # Clean up PySAT solver
    if pysat_solver is not None:
        pysat_solver.delete()
    
    print("=" * 60)
    
    return key


if __name__ == '__main__':
    main()
