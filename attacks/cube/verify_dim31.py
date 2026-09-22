#!/usr/bin/env python3
"""
verify_dim31.py — Empirical verification of dim-31 SAT cube predictions.

Uses the parallel C binary (verify_cube_par) for fast 2^31 cube sums,
then compares against SAT model predictions.

Usage:
    python3 cube/verify_dim31.py [--const-bit 31] [--nkeys 5] [--rounds 32,48,64,72,80]
"""

import sys, os, time, subprocess, argparse, shutil

# Resolve paths relative to this script so it works from any working directory
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT        = os.path.dirname(_SCRIPT_DIR)
sys.path.insert(0, ROOT)
from cube.keeloq_monomial import KeeLoqMonomialModel, make_solver

# ── Paths ────────────────────────────────────────────────────────────────
C_SRC    = os.path.join(ROOT, 'cube', 'verify_cube_par.c')
C_BIN    = os.path.join(ROOT, 'cube', 'verify_cube_par')

def _binary_matches_platform(path):
    """Check whether an existing binary matches the current OS (ELF vs Mach-O)."""
    try:
        with open(path, 'rb') as f:
            magic = f.read(4)
    except OSError:
        return False
    is_elf   = magic[:4] == b'\x7fELF'
    is_macho = magic[:4] in (b'\xfe\xed\xfa\xce', b'\xfe\xed\xfa\xcf',
                              b'\xce\xfa\xed\xfe', b'\xcf\xfa\xed\xfe')
    if sys.platform.startswith('linux'):
        return is_elf
    elif sys.platform == 'darwin':
        return is_macho
    return True  # unknown platform — assume OK


def ensure_binary():
    """Compile the parallel C binary if needed."""
    if (os.path.isfile(C_BIN) and
        os.path.getmtime(C_BIN) >= os.path.getmtime(C_SRC) and
        _binary_matches_platform(C_BIN)):
        return  # already up-to-date and correct format

    cc = 'gcc'
    if not shutil.which(cc):
        cc = 'cc'
    cmd = [cc, '-O2', '-o', C_BIN, C_SRC, '-lpthread']
    print(f"  Compiling: {' '.join(cmd)}")
    subprocess.check_call(cmd)
    print(f"  Binary ready: {C_BIN}")


def emp_key_independent(nrounds, cube_bits, nkeys=5, seed=42, timeout=1200):
    """
    Call the parallel C binary and parse the KEY_INDEPENDENT output line.
    Returns list of key-independent bit indices (same value for ALL keys,
    whether that value is 0 or 1).
    """
    args = [C_BIN, str(nrounds), str(nkeys), str(seed)] + \
           [str(b) for b in cube_bits]
    result = subprocess.run(args, capture_output=True, text=True,
                            timeout=timeout)

    # Progress goes to stderr — relay to user
    if result.stderr:
        for line in result.stderr.strip().split('\n'):
            print(f"    [C] {line}")

    # Parse "KEY_INDEPENDENT <count> [bit0 bit1 ...]" from stdout
    for line in result.stdout.strip().split('\n'):
        if line.startswith('KEY_INDEPENDENT'):
            parts = line.split()
            count = int(parts[1])
            bits  = [int(x) for x in parts[2:2+count]]
            return bits

    raise RuntimeError(f"Failed to parse C output:\n{result.stdout}\n{result.stderr}")


def sat_key_independent(nrounds, cube_bits):
    """Run SAT model and return list of key-independent bit indices."""
    model  = KeeLoqMonomialModel(nrounds)
    solver = make_solver(model)
    bal    = model.find_balanced_bits(cube_bits, solver)
    solver.delete()
    return bal


def main():
    parser = argparse.ArgumentParser(description='Dim-31 empirical verification')
    parser.add_argument('--const-bit', type=int, default=31,
                        help='Bit excluded from cube (default: 31)')
    parser.add_argument('--nkeys', type=int, default=5,
                        help='Number of random keys (default: 5)')
    parser.add_argument('--seed', type=int, default=42,
                        help='PRNG seed (default: 42)')
    parser.add_argument('--rounds', type=str,
                        default='32,48,64,72,80',
                        help='Comma-separated round counts (default: 32,48,64,72,80)')
    parser.add_argument('--timeout', type=int, default=1200,
                        help='Timeout per round test in seconds (default: 1200)')
    args = parser.parse_args()

    test_rounds = [int(r) for r in args.rounds.split(',')]
    const_bit   = args.const_bit
    cube        = sorted(j for j in range(32) if j != const_bit)
    nkeys       = args.nkeys
    ncores      = os.cpu_count() or 1

    print('=' * 72)
    print(f'Empirical verification of dim-31 SAT predictions  (const_bit={const_bit})')
    print(f'Rounds to test : {test_rounds}')
    print(f'Keys per test  : {nkeys}  (seed={args.seed})')
    print(f'CPU cores       : {ncores}  (detected dynamically)')
    print(f'Cube bits       : {{0..31}} \\ {{{const_bit}}}  (dim={len(cube)})')
    print('=' * 72)

    ensure_binary()

    all_ok = True
    for R in test_rounds:
        print(f'\n{"─"*72}')
        print(f'R = {R}')
        print(f'{"─"*72}')

        # SAT prediction (key-independent = no key-dependent monomial trail)
        t0 = time.time()
        s_ki = sat_key_independent(R, cube)
        t_sat = time.time() - t0
        print(f'  SAT  : {len(s_ki):2d} key-indep bits  ({t_sat:.2f}s)  {s_ki}')

        # Empirical (parallel)
        print(f'  Empirical ({nkeys} keys × 2^{len(cube)} encryptions, {ncores} threads):')
        t0 = time.time()
        e_ki = emp_key_independent(R, cube, nkeys=nkeys, seed=args.seed,
                                   timeout=args.timeout)
        t_emp = time.time() - t0
        print(f'  Emp  : {len(e_ki):2d} key-indep bits  ({t_emp:.1f}s)  {e_ki}')

        # Compare
        sat_set = set(s_ki)
        emp_set = set(e_ki)
        sat_only = sat_set - emp_set
        emp_only = emp_set - sat_set

        if sat_only:
            print(f'  *** BUG: SAT falsely claims bits {sorted(sat_only)} key-independent!')
            all_ok = False
        elif sat_set == emp_set:
            print(f'  PERFECT MATCH ✓')
        else:
            print(f'  SOUND (SAT ⊆ emp) ✓  — emp finds {len(emp_only)} extra: {sorted(emp_only)}')

    print(f'\n{"="*72}')
    if all_ok:
        print('All tests passed — SAT model is sound.')
    else:
        print('*** SOME TESTS FAILED — SAT model may have bugs!')
    print(f'{"="*72}')


if __name__ == '__main__':
    main()
