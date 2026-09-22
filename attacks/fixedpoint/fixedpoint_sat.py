#!/usr/bin/env python3
"""
fixedpoint_sat.py — KeeLoq Fixed-Point Attack Phase 2: Recovery of k[16..63]

Reads fixedpoint_data.txt from Phase 1 and recovers the remaining 48 key bits
with a hybrid Phase 2:
    - directed-pair SAT for groups with n >= 2
    - exact singleton constructive recovery for groups with n = 1

Theory:
  Phase 1 gives us k[0..15] and a set of F^8 fixed-point candidates (S, C, M16).
  For each candidate, M16 = E_16(k[0..15], S), the state after 16 rounds.

  For a true F^8 fixed point S with cycle length d | 8:
    E_64(K, S) maps S to another candidate in its cycle.
    E_48(k[16..63], M16) = E_64(K, S) = "successor of S in the cycle"

  Strategy:
    Directed-pair sweep (n >= 2):
      Fix two source candidates (indices 0, 1).  For each of the n^2
      target combinations (b, d), hypothesize F(cand[0]) = cand[b] and
      F(cand[1]) = cand[d], and solve a 2-pair SAT.  This is exhaustive
      and covers all cycle types (1/2/4/8) uniformly in n^2 calls.
        Exact singleton recovery (n = 1):
            Since m=1 implies a 1-cycle, solve E_48(k[16..63], M16) = S.
            Enumerate the exact 2^16 residual solutions constructively by guessing
            the first 16 feedback bits, derive k[16..63] directly, and verify each
            candidate against cross-verification pairs.

Usage:
  python3 fixedpoint_sat.py [--data fixedpoint_data.txt] [--key 0x...]
  
  --key is optional, for verification only.

Requirements:
  pip install pycryptosat python-sat
"""

import argparse
import ctypes
import sys
import os
import subprocess
import struct
import tempfile
import time
import multiprocessing
import random
from typing import List

# ========================== KeeLoq Reference ==========================

NLF_CONSTANT = 0x3A5C742E
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_SINGLETON_HELPER = None
_SINGLETON_HELPER_LOAD_FAILED = False
_SINGLETON_GPU_HELPER = os.path.join(SCRIPT_DIR, 'singleton_gpu_prefilter')


def _singleton_helper_path():
    ext = '.dylib' if sys.platform == 'darwin' else '.so'
    return os.path.join(SCRIPT_DIR, f'singleton_helper{ext}')


def _build_singleton_helper():
    lib_path = _singleton_helper_path()
    helper_src = os.path.join(SCRIPT_DIR, 'singleton_helper.c')
    keeloq_src = os.path.join(SCRIPT_DIR, 'keeloq.c')
    if sys.platform == 'darwin':
        cmd = ['cc', '-O3', '-fPIC', '-dynamiclib', '-o', lib_path, helper_src, keeloq_src]
    else:
        cmd = ['cc', '-O3', '-fPIC', '-shared', '-o', lib_path, helper_src, keeloq_src]
    subprocess.run(cmd, cwd=SCRIPT_DIR, check=True, capture_output=True, text=True)
    return lib_path


def _ensure_singleton_gpu_helper_built(verbose=False):
    gpu_src = os.path.join(SCRIPT_DIR, 'singleton_gpu_prefilter.cu')
    if not os.path.exists(gpu_src):
        return False
    if os.path.exists(_SINGLETON_GPU_HELPER):
        exe_mtime = os.path.getmtime(_SINGLETON_GPU_HELPER)
        deps = [gpu_src, os.path.join(SCRIPT_DIR, 'keeloq.h')]
        if all(os.path.exists(dep) and os.path.getmtime(dep) <= exe_mtime for dep in deps):
            return True
    try:
        subprocess.run(
            ['nvcc', '-O3', '--use_fast_math', '-o', _SINGLETON_GPU_HELPER, gpu_src],
            cwd=SCRIPT_DIR,
            check=True,
            capture_output=True,
            text=True,
        )
        return True
    except Exception as exc:
        if verbose:
            print(f"  [!] Singleton GPU helper unavailable, falling back to CPU: {exc}")
        return False


def _ensure_singleton_helper_built(verbose=False):
    lib_path = _singleton_helper_path()
    deps = [
        os.path.join(SCRIPT_DIR, 'singleton_helper.c'),
        os.path.join(SCRIPT_DIR, 'keeloq.c'),
        os.path.join(SCRIPT_DIR, 'keeloq.h'),
    ]
    if os.path.exists(lib_path):
        lib_mtime = os.path.getmtime(lib_path)
        if all(os.path.exists(dep) and os.path.getmtime(dep) <= lib_mtime for dep in deps):
            return True
    try:
        global _SINGLETON_HELPER, _SINGLETON_HELPER_LOAD_FAILED
        _build_singleton_helper()
        _SINGLETON_HELPER = None
        _SINGLETON_HELPER_LOAD_FAILED = False
        return True
    except Exception as exc:
        if verbose:
            print(f"  [!] Singleton C helper unavailable, falling back to Python: {exc}")
        return False


def _load_singleton_helper():
    global _SINGLETON_HELPER, _SINGLETON_HELPER_LOAD_FAILED
    if _SINGLETON_HELPER_LOAD_FAILED:
        return None
    if _SINGLETON_HELPER is not None:
        return _SINGLETON_HELPER

    lib_path = _singleton_helper_path()
    if not os.path.exists(lib_path):
        return None

    try:
        lib = ctypes.CDLL(lib_path)
        helper_fn = lib.search_singleton_constructive
        helper_fn.argtypes = [
            ctypes.c_uint16,
            ctypes.c_uint32,
            ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_uint32),
            ctypes.POINTER(ctypes.c_uint32),
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_uint64),
            ctypes.POINTER(ctypes.c_uint32),
        ]
        helper_fn.restype = ctypes.c_int
        _SINGLETON_HELPER = lib
        return lib
    except (OSError, AttributeError):
        _SINGLETON_HELPER_LOAD_FAILED = True
        return None


def _gpu_prefilter_singletons(singleton_groups, verify_pairs, verbose=False):
    """
    Exhaustively prefilter singleton groups on GPU using the first two extra pairs.

    This preserves exactness because it searches every (group, prefix16) pair;
    CPU then verifies the tiny survivor set against the full verify_extra list.
    """
    if len(singleton_groups) == 0 or len(verify_pairs) < 2:
        return None
    if not _ensure_singleton_gpu_helper_built(verbose=verbose):
        return None

    fd_in, path_in = tempfile.mkstemp(prefix='singleton_gpu_in_', suffix='.bin')
    os.close(fd_in)
    fd_out, path_out = tempfile.mkstemp(prefix='singleton_gpu_out_', suffix='.bin')
    os.close(fd_out)

    try:
        with open(path_in, 'wb') as f:
            f.write(struct.pack('<II', len(singleton_groups), len(verify_pairs[:2])))
            for (group_idx, k16, _votes, candidates) in singleton_groups:
                s_target, _c_val, m16 = candidates[0]
                f.write(struct.pack('<I H H I I', group_idx, k16, 0, s_target, m16))
            for (sx, cx) in verify_pairs[:2]:
                f.write(struct.pack('<II', sx, cx))

        subprocess.run([_SINGLETON_GPU_HELPER, path_in, path_out], cwd=SCRIPT_DIR, check=True)

        survivors = []
        with open(path_out, 'rb') as f:
            raw = f.read(4)
            if len(raw) != 4:
                return []
            count, = struct.unpack('<I', raw)
            for _ in range(count):
                rec = f.read(16)
                if len(rec) != 16:
                    break
                group_idx, prefix16, key_cand = struct.unpack('<IIQ', rec)
                survivors.append((group_idx, prefix16, key_cand))
        return survivors
    except Exception:
        return None
    finally:
        for path in (path_in, path_out):
            try:
                os.remove(path)
            except OSError:
                pass

def nlf(x4, x3, x2, x1, x0):
    index = (x4 << 4) | (x3 << 3) | (x2 << 2) | (x1 << 1) | x0
    return (NLF_CONSTANT >> index) & 1

def keeloq_encrypt(key: int, plaintext: int, rounds: int = 528) -> int:
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

# ========================== SAT Encoding ==============================

class KeeLoqSAT48:
    """
    SAT encoder for 48-round KeeLoq (rounds 16..63).

    Variable layout (1-indexed for DIMACS):
      k[0..63]:     key bits           (vars 1..64)
      L[p][0..79]:  state bits per pair (32 input + 48 round bits)

    Key schedule: round i uses k[(i + 16) % 64], so for i=0..47
    this accesses k[16], k[17], ..., k[63].
    k[0..15] are fixed via unit clauses (not used in rounds, but
    ensures extracted key has correct lower bits).
    """

    def __init__(self, num_pairs: int = 1):
        self.rounds = 48
        self.num_pairs = num_pairs
        self.key_offset = 16
        self.num_state = 32 + 48  # 80 state vars per pair

        # Variable allocation
        self.next_var = 1

        # Key variables (shared across pairs)
        self.k = list(range(1, 65))
        self.next_var = 65

        # State variables per pair
        self.L = []
        for _ in range(num_pairs):
            pair_vars = list(range(self.next_var, self.next_var + self.num_state))
            self.L.append(pair_vars)
            self.next_var += self.num_state

        # NLF auxiliary variable cache
        self.aux_vars = {}

    def new_var(self) -> int:
        v = self.next_var
        self.next_var += 1
        return v

    def get_nlf_cnf(self, x4, x3, x2, x1, x0):
        """Minimized 14-clause CNF for NLF (from SboxAnalyzer)."""
        key = (x4, x3, x2, x1, x0)
        if key in self.aux_vars:
            return self.aux_vars[key], []

        out = self.new_var()
        self.aux_vars[key] = out

        clauses = [
            [x3, x2, -x1, out],
            [-x3, -x2, x1, out],
            [-x4, -x3, -x2, -x1, -out],
            [x4, x3, -x2, -x1, -out],
            [x4, -x3, x2, x1, -out],
            [-x4, x3, x2, x1, -out],
            [-x4, x3, -x2, -x0, -out],
            [x4, -x3, -x1, -x0, -out],
            [-x4, -x3, x2, x0, -out],
            [x4, x3, x1, x0, -out],
            [-x4, -x3, x2, -x0, out],
            [x4, x3, x1, -x0, out],
            [-x4, x3, -x2, x0, out],
            [x4, -x3, -x1, x0, out],
        ]
        return out, clauses

    def get_xor_cnf(self, lits: List[int], rhs: int) -> List[List[int]]:
        """Encode XOR as CNF using Tseitin chain."""
        if len(lits) == 0:
            return [[]] if rhs == 1 else []
        if len(lits) == 1:
            return [[lits[0]]] if rhs == 1 else [[-lits[0]]]
        if len(lits) == 2:
            a, b = lits
            if rhs == 0:
                return [[a, -b], [-a, b]]
            else:
                return [[a, b], [-a, -b]]

        clauses = []
        current = lits[0]
        for i in range(1, len(lits)):
            next_lit = lits[i]
            if i == len(lits) - 1:
                if rhs == 0:
                    clauses.extend([[current, -next_lit], [-current, next_lit]])
                else:
                    clauses.extend([[current, next_lit], [-current, -next_lit]])
            else:
                aux = self.new_var()
                clauses.extend([
                    [-current, -next_lit, -aux],
                    [-current, next_lit, aux],
                    [current, -next_lit, aux],
                    [current, next_lit, -aux]
                ])
                current = aux
        return clauses

    def build(self, k16: int, inputs: List[int], outputs: List[int]):
        """
        Build SAT instance.
        
        Args:
            k16:     known k[0..15] (16-bit)
            inputs:  list of M16 values (state after round 15)
            outputs: list of expected outputs (= S for 1-cycle fixed points)
        
        Returns:
            (cnf_clauses, xor_clauses) for CryptoMiniSat
        """
        assert len(inputs) == len(outputs) == self.num_pairs
        self.aux_vars = {}

        cnf_clauses = []
        xor_clauses = []

        # Fix k[0..15] as unit clauses
        for i in range(16):
            bit = (k16 >> i) & 1
            cnf_clauses.append([self.k[i] if bit else -self.k[i]])

        for p in range(self.num_pairs):
            M16 = inputs[p]
            target = outputs[p]
            L = self.L[p]

            # Fix input state = M16
            for j in range(32):
                bit = (M16 >> j) & 1
                cnf_clauses.append([L[j] if bit else -L[j]])

            # Round constraints
            for i in range(self.rounds):
                j = 32 + i

                # NLF inputs: bits at positions j-1, j-6, j-12, j-23, j-31 of L
                x4, x3, x2, x1, x0 = L[j-1], L[j-6], L[j-12], L[j-23], L[j-31]

                nlf_out, nlf_cnf = self.get_nlf_cnf(x4, x3, x2, x1, x0)
                cnf_clauses.extend(nlf_cnf)

                # Feedback XOR: L[j] ^ k[(i+key_offset)%64] ^ L[j-16] ^ L[j-32] ^ nlf_out = 0
                key_idx = (i + self.key_offset) % 64
                xor_clauses.append(([L[j], self.k[key_idx], L[j-16], L[j-32], nlf_out], False))

            # Fix output state = target
            for j in range(32):
                bit = (target >> j) & 1
                state_idx = self.rounds + j
                cnf_clauses.append([L[state_idx] if bit else -L[state_idx]])

        return cnf_clauses, xor_clauses

    def build_cnf_only(self, k16: int, inputs: List[int], outputs: List[int]):
        """Build pure CNF (for PySAT solvers without native XOR)."""
        assert len(inputs) == len(outputs) == self.num_pairs
        self.aux_vars = {}

        clauses = []

        # Fix k[0..15]
        for i in range(16):
            bit = (k16 >> i) & 1
            clauses.append([self.k[i] if bit else -self.k[i]])

        for p in range(self.num_pairs):
            M16 = inputs[p]
            target = outputs[p]
            L = self.L[p]

            # Fix input state
            for j in range(32):
                bit = (M16 >> j) & 1
                clauses.append([L[j] if bit else -L[j]])

            # Round constraints
            for i in range(self.rounds):
                j = 32 + i
                x4, x3, x2, x1, x0 = L[j-1], L[j-6], L[j-12], L[j-23], L[j-31]
                nlf_out, nlf_cnf = self.get_nlf_cnf(x4, x3, x2, x1, x0)
                clauses.extend(nlf_cnf)

                key_idx = (i + self.key_offset) % 64
                lits = [L[j], self.k[key_idx], L[j-16], L[j-32], nlf_out]
                clauses.extend(self.get_xor_cnf(lits, 0))

            # Fix output state
            for j in range(32):
                bit = (target >> j) & 1
                state_idx = self.rounds + j
                clauses.append([L[state_idx] if bit else -L[state_idx]])

        return clauses

    def extract_key(self, model) -> int:
        """Extract 64-bit key from solver model."""
        key = 0
        if isinstance(model, (list, tuple)):
            if isinstance(model[0], bool) or model[0] is None:
                # CryptoMiniSat model: tuple of True/False/None
                for i in range(64):
                    if model[self.k[i]]:
                        key |= (1 << i)
            else:
                # PySAT model: list of signed integers
                model_set = set(model)
                for i in range(64):
                    if self.k[i] in model_set:
                        key |= (1 << i)
        return key


# ========================== Parse Phase 1 Output ======================

def parse_fixedpoint_data(filepath: str):
    """
    Parse fixedpoint_data.txt from Phase 1.
    
    Supports both old single-group format and new multi-group format.
    Returns list of (k16, votes, candidates) groups sorted by votes descending.
    Each candidate is a tuple (S, C, M16).
    """
    groups = []
    current_k16 = None
    current_votes = 0
    current_candidates = []

    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if line == '[group]':
                # Save previous group if any
                if current_k16 is not None and current_candidates:
                    groups.append((current_k16, current_votes, current_candidates))
                current_k16 = None
                current_votes = 0
                current_candidates = []
                continue
            if line.startswith('k16='):
                current_k16 = int(line.split('=')[1], 16)
                continue
            if line.startswith('votes='):
                current_votes = int(line.split('=')[1])
                continue
            # Parse "0xSSSSSSSS 0xCCCCCCCC 0xMMMMMMMM"
            parts = line.split()
            if len(parts) == 3:
                S = int(parts[0], 16)
                C = int(parts[1], 16)
                M16 = int(parts[2], 16)
                current_candidates.append((S, C, M16))

    # Save last group
    if current_k16 is not None and current_candidates:
        groups.append((current_k16, current_votes, current_candidates))

    # Sort by votes descending
    groups.sort(key=lambda g: -g[1])
    return groups


def parse_phase1_metadata(filepath: str):
    """Parse optional Phase 1 metadata comments from fixedpoint_data.txt."""
    meta = {}
    try:
        with open(filepath, 'r') as f:
            for line in f:
                line = line.strip()
                if not line.startswith('#'):
                    continue
                if '=' not in line:
                    continue
                payload = line[1:].strip()
                k, v = payload.split('=', 1)
                meta[k.strip()] = v.strip()
    except OSError:
        pass
    return meta


# ========================== SAT Pair Solver ===========================

def try_pair_sat(enc, k16, M16_i, target_i, M16_j, target_j,
                 candidates, max_enum=100, verify_extra=None):
    """
    Build 2-pair SAT and enumerate solutions, verifying each against all
    candidates AND optional extra (S,C) pairs for cross-group validation.
    Returns recovered key or None.
    """
    from pysat.solvers import Solver as PySATSolver
    clauses = enc.build_cnf_only(k16, [M16_i, M16_j], [target_i, target_j])
    solver = PySATSolver(name='cadical153', bootstrap_with=clauses)

    t0 = time.time()
    sat = solver.solve()

    if not sat:
        elapsed = time.time() - t0
        solver.delete()
        return None, 0, elapsed, False

    sol_count = 0
    while sat and sol_count < max_enum:
        model = solver.get_model()
        key_cand = enc.extract_key(model)
        sol_count += 1

        # Verify against group candidates
        all_ok = True
        for (S_c, C_c, _) in candidates:
            if keeloq_encrypt(key_cand, S_c, 528) != C_c:
                all_ok = False
                break

        # Cross-verify against extra pairs from other groups
        if all_ok and verify_extra:
            for (S_x, C_x) in verify_extra:
                if keeloq_encrypt(key_cand, S_x, 528) != C_x:
                    all_ok = False
                    break

        if all_ok:
            elapsed = time.time() - t0
            solver.delete()
            return key_cand, sol_count, elapsed, True

        # Block and continue
        blocking = []
        for bit_i in range(64):
            bit = (key_cand >> bit_i) & 1
            blocking.append(-enc.k[bit_i] if bit else enc.k[bit_i])
        solver.add_clause(blocking)
        sat = solver.solve()

    elapsed = time.time() - t0
    solver.delete()
    return None, sol_count, elapsed, False


# ========================== Group Recovery ============================

def _try_directed_pairs(k16, candidates, verify_extra=None):
    """
    Unified directed-pair search: fix two source candidates (indices 0, 1)
    and sweep all n^2 target combinations with 2-pair SAT.

    For a true group of size n >= 2, the correct F-images of candidates[0]
    and candidates[1] are both among the n candidates, so this sweep is
    exhaustive and guaranteed to find the key.

    Covers all cycle types uniformly (1-cycles, 2-cycles, 4-cycles, 8-cycles)
    in n^2 SAT calls.
    """
    n = len(candidates)
    if n < 2:
        return None, ""

    M16_0 = candidates[0][2]
    M16_1 = candidates[1][2]

    for b in range(n):
        S_b = candidates[b][0]
        for d in range(n):
            S_d = candidates[d][0]
            enc = KeeLoqSAT48(num_pairs=2)
            key_cand, _, _, ok = try_pair_sat(
                enc, k16, M16_0, S_b, M16_1, S_d, candidates,
                verify_extra=verify_extra)
            if ok:
                return key_cand, "directed"
    return None, ""


def _print_phase2_meta(stage, step, group_idx, group_size, votes):
    """Emit a machine-parseable metadata line for benchmark parsing."""
    print(f"PHASE2_META stage={stage} step={step} group={group_idx + 1} n={group_size} votes={votes}")


def _singleton_candidate_from_feedback_prefix(k16, s_target, m16, prefix16):
    """
    Reconstruct one singleton key candidate from the 16 unknown feedback bits.

    For a singleton, F(S) = S, so the 48-round relation is:
        E_48(k[16..63], M16) = S

    The final 32 output bits reveal feedback bits f[16..47] directly:
        f[i] = bit (i - 16) of S,  for i = 16..47

    Guessing only f[0..15] determines the whole 48-round state trajectory, and
    each round then yields one key bit from:
        f_i = k_{16+i} xor state[16] xor state[0] xor NLF(...)
    """
    state = m16
    key = k16
    for i in range(48):
        if i < 16:
            feedback = (prefix16 >> i) & 1
        else:
            feedback = (s_target >> (i - 16)) & 1
        key_bit = feedback ^ ((state >> 16) & 1) ^ (state & 1) ^ nlf(
            (state >> 31) & 1,
            (state >> 26) & 1,
            (state >> 20) & 1,
            (state >> 9) & 1,
            (state >> 1) & 1,
        )
        key |= key_bit << (16 + i)
        state = ((state >> 1) | (feedback << 31)) & 0xFFFFFFFF
    return key


def _try_single_as_1cycle_python(k16, s_target, m16, verify_extra):
    """
    Try a singleton candidate assuming a 1-cycle (F(S) = S).

    This relation leaves exactly 16 degrees of freedom. Instead of enumerating
    SAT models, enumerate the 16 unknown feedback bits directly, reconstruct the
    full 64-bit key candidate, and verify it against extra (S, C) pairs.
    """
    if not verify_extra:
        return None, 0

    first_s, first_c = verify_extra[0]
    rest_extra = verify_extra[1:]

    for prefix16 in range(1 << 16):
        key_cand = _singleton_candidate_from_feedback_prefix(k16, s_target, m16, prefix16)
        if keeloq_encrypt(key_cand, first_s, 528) != first_c:
            continue
        if all(keeloq_encrypt(key_cand, sx, 528) == cx for (sx, cx) in rest_extra):
            return key_cand, prefix16 + 1
    return None, 1 << 16


def _try_single_as_1cycle(k16, s_target, m16, verify_extra):
    helper = _load_singleton_helper()
    if helper is not None and verify_extra:
        verify_s = (ctypes.c_uint32 * len(verify_extra))(*[sx for (sx, _) in verify_extra])
        verify_c = (ctypes.c_uint32 * len(verify_extra))(*[cx for (_, cx) in verify_extra])
        out_key = ctypes.c_uint64(0)
        prefixes_tested = ctypes.c_uint32(0)
        ok = helper.search_singleton_constructive(
            k16,
            s_target,
            m16,
            verify_s,
            verify_c,
            len(verify_extra),
            ctypes.byref(out_key),
            ctypes.byref(prefixes_tested),
        )
        if ok:
            return out_key.value, prefixes_tested.value
        return None, prefixes_tested.value
    return _try_single_as_1cycle_python(k16, s_target, m16, verify_extra)

def _recover_group_silent(k16, candidates, verify_extra=None):
    """
    Recover k[16..63] from one group.  No output (for multiprocessing workers).
    - n >= 2: directed-pair sweep (exhaustive, n^2 SAT calls)
    - n = 1: constructive 1-cycle enumeration with cross-verification
    Returns (key or None, step_label).
    """
    n = len(candidates)
    if n < 1:
        return None, "", 0
    if n == 1:
        S, C, M16 = candidates[0]
        key, tested_prefixes = _try_single_as_1cycle(k16, S, M16, verify_extra)
        return key, "singleton" if key is not None else "", tested_prefixes
    key, step = _try_directed_pairs(k16, candidates, verify_extra=verify_extra)
    return key, step, 0


def _worker_pass1(args):
    """Multiprocessing worker: recover key from one group."""
    group_idx, k16, candidates, verify_extra = args
    key, step, tested_prefixes = _recover_group_silent(k16, candidates, verify_extra=verify_extra)
    return (group_idx, k16, key, step, tested_prefixes)



# ========================== Main ======================================

def main():
    parser = argparse.ArgumentParser(
        description='KeeLoq Fixed-Point Attack Phase 2: Recovery of k[16..63]'
    )
    parser.add_argument(
        '--data', '-d', type=str, default='fixedpoint_data.txt',
        help='Path to Phase 1 output file (default: fixedpoint_data.txt)'
    )
    parser.add_argument(
        '--key', '-k', type=lambda x: int(x, 0), default=None,
        help='True key for verification (optional, hex)'
    )
    parser.add_argument(
        '--solver', '-s', choices=['cryptominisat', 'cadical'],
        default='cadical',
        help='SAT solver (default: cadical)'
    )
    parser.add_argument(
        '--workers', '-w', type=int, default=0,
        help='Number of parallel Phase 2 workers (default: all CPUs)'
    )
    parser.add_argument(
        '--group-shuffle-seed', '--step4-seed', dest='group_shuffle_seed', type=int, default=42,
        help='Seed for shuffling equal-vote groups (default: 42)'
    )
    args = parser.parse_args()
    phase2_t0 = time.time()

    nworkers = args.workers if args.workers > 0 else multiprocessing.cpu_count()

    # ---- Read Phase 1 data ----
    W = 72
    print()
    print("═" * W)
    print(" KeeLoq Fixed-Point Attack // Phase 2 (Recovery) ".center(W))
    print("═" * W)
    print()

    if not os.path.exists(args.data):
        print(f"ERROR: {args.data} not found. Run Phase 1 first:")
        print("  make phase1")
        sys.exit(1)

    groups = parse_fixedpoint_data(args.data)
    if not groups:
        print("ERROR: No valid groups in", args.data)
        sys.exit(1)

    phase1_meta = parse_phase1_metadata(args.data)
    phase1_scan_seconds = 0.0
    if 'phase1_scan_seconds' in phase1_meta:
        try:
            phase1_scan_seconds = float(phase1_meta['phase1_scan_seconds'])
        except ValueError:
            phase1_scan_seconds = 0.0

    # Randomize order only within equal-vote groups while keeping vote priority intact.
    # Since each survivor contributes one vote to exactly one k16 bin, singleton
    # groups necessarily have votes == len(candidates) == 1, so their relative
    # order is just the inherited equal-vote tie order from this list.
    groups_by_votes = {}
    for item in groups:
        groups_by_votes.setdefault(item[1], []).append(item)
    rng = random.Random(args.group_shuffle_seed)
    groups = []
    for votes in sorted(groups_by_votes.keys(), reverse=True):
        bucket = groups_by_votes[votes]
        if len(bucket) > 1:
            rng.shuffle(bucket)
        groups.extend(bucket)

    true_k16 = (args.key & 0xFFFF) if args.key else None

    # Include all groups (n >= 1): n>=2 handled by directed-pair SAT,
    # n=1 handled by constructive singleton enumeration.
    eligible = [(g, k16, v, c) for g, (k16, v, c) in enumerate(groups) if len(c) >= 1]
    eligible_n2plus = [(g, k16, v, c) for (g, k16, v, c) in eligible if len(c) >= 2]
    eligible_n1 = [(g, k16, v, c) for (g, k16, v, c) in eligible if len(c) == 1]

    print(f"  [*] Groups      : {len(groups):>6} total")
    print(f"                    {len(eligible_n2plus):>6} with >= 2 candidates")
    print(f"                    {len(eligible_n1):>6} with 1 candidate")
    print(f"  [*] Workers     : {nworkers:>6}")
    if args.key:
        print(f"  [*] True key    : 0x{args.key:016X}")
    print()
    print("  ┌─────┬────────────┬───────┬────────────┐")
    print("  │  #  │    k16     │ votes │ candidates │")
    print("  ├─────┼────────────┼───────┼────────────┤")
    for g, (k16, votes, cands) in enumerate(groups[:10]):
        marker = " <<" if (true_k16 is not None and k16 == true_k16) else ""
        print(f"  │ {g+1:>3} │ 0x{k16:04x}     │ {votes:>5} │ {len(cands):>10} │{marker}")
    if len(groups) > 10:
        print(f"  │ ... │    ...     │  ...  │    ...     │  (+{len(groups)-10} more)")
    print("  └─────┴────────────┴───────┴────────────┘")
    print()

    # ---- Collect cross-verification pairs ----
    # A group with only 2 candidates provides 64 bits of constraint on
    # the 64-bit key, so ~1 spurious key is expected. To filter these
    # false positives, we verify recovered keys against extra (S, C)
    # pairs sampled from other groups. 20 pairs add 640 bits of
    # filtering, making false positives negligible.
    import random as _rng
    _rng.seed(42)
    all_sc_pairs = []
    for (_, _, _, cands) in eligible:
        for (S, C, _) in cands:
            all_sc_pairs.append((S, C))
    _rng.shuffle(all_sc_pairs)
    verify_extra = all_sc_pairs[:20]
    print(f"  [*] Cross-verify: {len(verify_extra)} pairs")
    print()

    # ---- Sweep A: directed-pair for n>=2 groups (fast) ----
    print("─" * W)
    print(f"  [SWEEP A] Directed-pair SAT  |  {len(eligible_n2plus)} groups (n>=2)  |  {nworkers} workers")
    print("─" * W)
    print()

    pass1_t0 = time.time()
    recovered_key = None
    recovered_candidates = None

    # Build work items for n>=2 groups only.
    # Preserve vote priority, but within the same vote count prefer smaller
    # groups first because their exact directed-pair cost is about n^2.
    eligible_n2plus_scheduled = sorted(
        eligible_n2plus,
        key=lambda item: (-item[2], len(item[3]), item[0]),
    )
    work_a = [(g, k16, c, verify_extra) for (g, k16, v, c) in eligible_n2plus_scheduled]

    with multiprocessing.Pool(processes=nworkers) as pool:
        # One group per chunk avoids bundling a heavy group with lighter work,
        # which reduces stragglers without changing the searched space.
        results = pool.imap_unordered(_worker_pass1, work_a, chunksize=1)
        done = 0
        for (group_idx, k16, key, step, tested_prefixes) in results:
            done += 1
            if done % 500 == 0 or key is not None:
                elapsed = time.time() - pass1_t0
                pct = 100.0 * done / len(eligible_n2plus)
                print(f"\r  [~] Progress: {done:>6}/{len(eligible_n2plus)} ({pct:5.1f}%)  |  {elapsed:>6.1f}s",
                      end="", flush=True)
            if key is not None:
                elapsed = time.time() - pass1_t0
                recovered_votes = 0
                recovered_size = 0
                for (g, gk16, v, c) in eligible:
                    if g == group_idx:
                        recovered_votes = v
                        recovered_size = len(c)
                        recovered_candidates = c
                        break
                print(f"\n\n  [+] FOUND @ group #{group_idx+1}  k16=0x{k16:04x}")
                print(f"      KEY: 0x{key:016X}")
                print(f"      Step: {step}")
                print(f"      Time: {elapsed:.1f}s  |  Groups tested: {done}")
                _print_phase2_meta("sweepA", step or "unknown", group_idx, recovered_size, recovered_votes)
                recovered_key = key
                pool.terminate()
                break

    sweepA_elapsed = time.time() - pass1_t0
    print(f"\n  [*] Sweep A complete: {sweepA_elapsed:.1f}s")

    # ---- Sweep B: exact singleton recovery for n=1 groups (only if Sweep A failed) ----
    if recovered_key is None and eligible_n1:
        # This optional GPU prefilter is a Phase 2 optimization for singleton
        # (group, prefix16) pairs. It is distinct from the Phase 1 filter.
        gpu_prefilter = _gpu_prefilter_singletons(eligible_n1, verify_extra, verbose=True)
        if gpu_prefilter is not None:
            helper_mode = 'GPU prefilter + CPU verify'
        else:
            helper_mode = 'C helper' if _ensure_singleton_helper_built(verbose=True) else 'Python fallback'
        print()
        print("─" * W)
        print(f"  [SWEEP B] Exact singleton recovery  |  {len(eligible_n1)} groups (n=1)  |  {nworkers} workers")
        print(f"            mode={helper_mode}")
        print("─" * W)
        print()

        if gpu_prefilter is not None:
            survivor_by_group = {}
            for (group_idx, prefix16, key_cand) in gpu_prefilter:
                survivor_by_group.setdefault(group_idx, []).append((prefix16, key_cand))
            done_b = 0
            for (group_idx, k16, votes, candidates) in eligible_n1:
                done_b += 1
                if done_b % 200 == 0:
                    elapsed = time.time() - pass1_t0
                    pct = 100.0 * done_b / len(eligible_n1)
                    print(f"\r  [~] Progress: {done_b:>6}/{len(eligible_n1)} ({pct:5.1f}%)  |  {elapsed:>6.1f}s",
                          end="", flush=True)
                survivors = survivor_by_group.get(group_idx)
                if survivors is None:
                    continue
                for (prefix16, key_cand) in survivors:
                    if all(keeloq_encrypt(key_cand, sx, 528) == cx for (sx, cx) in verify_extra):
                        elapsed = time.time() - pass1_t0
                        recovered_candidates = candidates
                        print(f"\n\n  [+] FOUND @ group #{group_idx+1}  k16=0x{k16:04x}")
                        print(f"      KEY: 0x{key_cand:016X}")
                        print(f"      Step: singleton")
                        print(f"      Time: {elapsed:.1f}s  |  Singletons tested: {done_b}")
                        print(f"      Prefixes tried in winning group: {prefix16 + 1}")
                        print(f"      GPU survivors after prefilter: {len(gpu_prefilter)}")
                        _print_phase2_meta("sweepB", "singleton", group_idx, len(candidates), votes)
                        recovered_key = key_cand
                        break
                if recovered_key is not None:
                    break
        else:
            work_b = [(g, k16, c, verify_extra) for (g, k16, v, c) in eligible_n1]

            with multiprocessing.Pool(processes=nworkers) as pool:
                results = pool.imap_unordered(_worker_pass1, work_b, chunksize=1)
                done_b = 0
                for (group_idx, k16, key, step, tested_prefixes) in results:
                    done_b += 1
                    if done_b % 200 == 0 or key is not None:
                        elapsed = time.time() - pass1_t0
                        pct = 100.0 * done_b / len(eligible_n1)
                        print(f"\r  [~] Progress: {done_b:>6}/{len(eligible_n1)} ({pct:5.1f}%)  |  {elapsed:>6.1f}s",
                              end="", flush=True)
                    if key is not None:
                        elapsed = time.time() - pass1_t0
                        recovered_votes = 0
                        recovered_size = 0
                        for (g, gk16, v, c) in eligible:
                            if g == group_idx:
                                recovered_votes = v
                                recovered_size = len(c)
                                recovered_candidates = c
                                break
                        print(f"\n\n  [+] FOUND @ group #{group_idx+1}  k16=0x{k16:04x}")
                        print(f"      KEY: 0x{key:016X}")
                        print(f"      Step: {step}")
                        print(f"      Time: {elapsed:.1f}s  |  Singletons tested: {done_b}")
                        print(f"      Prefixes tried in winning group: {tested_prefixes}")
                        _print_phase2_meta("sweepB", step or "unknown", group_idx, recovered_size, recovered_votes)
                        recovered_key = key
                        pool.terminate()
                        break

        sweepB_elapsed = time.time() - pass1_t0 - sweepA_elapsed
        print(f"\n  [*] Sweep B complete: {sweepB_elapsed:.1f}s")

    total_elapsed = time.time() - pass1_t0
    print(f"  [*] Phase 2 total: {total_elapsed:.1f}s")

    phase2_elapsed = time.time() - phase2_t0
    if recovered_key is not None:
        _print_result(recovered_key, recovered_candidates, args.key,
                      phase2_seconds=phase2_elapsed,
                      phase1_seconds=phase1_scan_seconds, width=W)
    else:
        print("  [-] Failed to recover key from any group")
        _print_result(None, groups[0][2] if groups else [], args.key,
                      phase2_seconds=phase2_elapsed,
                      phase1_seconds=phase1_scan_seconds, width=W)


def _fmt_time(seconds):
    """Format seconds as human-readable string, e.g. '3m 25s' or '1h 02m'."""
    if seconds < 60:
        return f"{seconds:.1f}s"
    m, s = divmod(int(seconds), 60)
    if m < 60:
        return f"{m}m {s:02d}s"
    h, m = divmod(m, 60)
    return f"{h}h {m:02d}m"


def _print_result(recovered_key, candidates, true_key, phase2_seconds=None, phase1_seconds=None, width=72):
    """Print final results."""
    W = width
    print()
    print("═" * W)
    if recovered_key is not None:
        print(" RESULT: KEY RECOVERED ".center(W))
        print("═" * W)
        print(f"  KEY      : 0x{recovered_key:016X}")
        print(f"  k[0..15] : 0x{recovered_key & 0xFFFF:04x}")
        print(f"  k[16..63]: 0x{(recovered_key >> 16) & 0xFFFFFFFFFFFF:012x}")
        print("─" * W)
        print("  528-round verification:")
        all_ok = True
        for idx, (S, C, M16) in enumerate(candidates[:6]):
            ct = keeloq_encrypt(recovered_key, S, 528)
            ok = (ct == C)
            status = "[OK]" if ok else "[!!]"
            line = f"    E(K, 0x{S:08x}) = 0x{ct:08x}  {status}"
            print(line)
            if not ok:
                all_ok = False
        print("─" * W)
        if true_key:
            if recovered_key == true_key:
                print(f"  [+] MATCH: 0x{true_key:016X}")
            else:
                print(f"  [!] DIFFERS from target: 0x{true_key:016X}")
                if all_ok:
                    print("      (verifies against all test pairs)")
    else:
        print(" RESULT: FAILED ".center(W))
        print("═" * W)
        print("  [-] Could not recover key from any group")

    print("─" * W)
    if phase1_seconds is not None and phase1_seconds > 0:
        print(f"  Phase 1      : {phase1_seconds:>8.1f}s  ({_fmt_time(phase1_seconds)})")
    if phase2_seconds is not None:
        print(f"  Phase 2      : {phase2_seconds:>8.1f}s  ({_fmt_time(phase2_seconds)})")
    if phase1_seconds is not None and phase1_seconds > 0 and phase2_seconds is not None:
        total = phase1_seconds + phase2_seconds
        print("─" * W)
        print(f"  TOTAL TIME   : {total:>8.1f}s  ({_fmt_time(total)})")
    print("═" * W)


if __name__ == '__main__':
    main()
