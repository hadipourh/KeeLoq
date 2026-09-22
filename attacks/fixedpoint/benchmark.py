#!/usr/bin/env python3
"""
benchmark.py — Run the fixed-point attack on N random keys and collect timing statistics.

For each random key:
    1. Phase 1: run fixedpoint_mt or fixedpoint_gpu → parse scan time
    2. Phase 2: run fixedpoint_sat.py               → parse recovery time
  3. Record success/failure, timings, and attack metadata

Produces:
  - fixedpoint_benchmark.csv   (per-key raw data)
  - fixedpoint_benchmark.txt   (summary statistics)

Usage:
    python3 benchmark.py [--num-keys 100] [--phase1-backend gpu] [--phase1-threads 256] [--phase2-threads 32] [--solver cadical]

Requires: fixedpoint_mt binary (will compile if missing), fixedpoint_sat.py
"""

import argparse
import csv
import math
import os
import random
import re
import subprocess
import sys
import time
from pathlib import Path

# ── Paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR = Path(__file__).resolve().parent
BIN_MT = SCRIPT_DIR / "fixedpoint_mt"
BIN_GPU = SCRIPT_DIR / "fixedpoint_gpu"
SAT_PY = SCRIPT_DIR / "fixedpoint_sat.py"
DATA_FILE = SCRIPT_DIR / "fixedpoint_data.txt"
CSV_FILE = SCRIPT_DIR / "fixedpoint_benchmark.csv"
TXT_FILE = SCRIPT_DIR / "fixedpoint_benchmark.txt"

# ── Python executable (prefer venv) ───────────────────────────────────
def find_python():
    for candidate in [SCRIPT_DIR / "venv" / "bin" / "python",
                      SCRIPT_DIR.parent / "venv" / "bin" / "python",
                      Path("venv/bin/python")]:
        if candidate.exists():
            return str(candidate)
    return sys.executable


def ensure_binary(backend: str = "cpu"):
    """Compile Phase 1 backend binary (always recompile to avoid arch mismatch)."""
    if backend == "gpu":
        print("[build] Compiling fixedpoint_gpu (CUDA)...")
        subprocess.run(
            ["nvcc", "-O3", "--use_fast_math",
             "-o", str(BIN_GPU), str(SCRIPT_DIR / "fixedpoint_gpu.cu")],
            check=True, cwd=str(SCRIPT_DIR)
        )
        print("[build] Done.")
    else:
        print("[build] Compiling fixedpoint_mt...")
        subprocess.run(
            ["cc", "-O3", "-march=native", "-Wall",
             "-o", str(BIN_MT), str(SCRIPT_DIR / "fixedpoint_mt.c"),
             "-lpthread"],
            check=True, cwd=str(SCRIPT_DIR)
        )
        print("[build] Done.")


def clean_data():
    """Remove Phase 1 output files."""
    for f in [DATA_FILE, SCRIPT_DIR / "survivors.csv"]:
        if f.exists():
            f.unlink()


def run_phase1(key_hex: str, threads: int, backend: str = "cpu"):
    """
    Run Phase 1 (C scan).
    Returns (success, scan_time_sec, survivors, votes_best, votes_true, rank_true, num_groups).
    """
    clean_data()
    t0 = time.time()
    phase1_bin = BIN_GPU if backend == "gpu" else BIN_MT
    result = subprocess.run(
        [str(phase1_bin), str(threads), key_hex],
        capture_output=True, text=True, cwd=str(SCRIPT_DIR),
        timeout=7200  # 2h max
    )
    wall_time = time.time() - t0

    stdout = result.stdout
    stderr = result.stderr

    # Parse scan time from C output ("Done: 194.0s")
    scan_time = wall_time
    m = re.search(r'Done:\s*([\d.]+)s', stdout)
    if m:
        scan_time = float(m.group(1))

    # Parse survivors
    survivors = 0
    m = re.search(r'Survivors:\s+(\d+)', stdout)
    if m:
        survivors = int(m.group(1))

    # Parse best k16 votes ("Best k16       :   0x557a  (votes: 7)")
    votes_best = 0
    m = re.search(r'Best k16\s*:\s*0x[0-9a-fA-F]+\s*\(votes:\s*(\d+)\)', stdout)
    if m:
        votes_best = int(m.group(1))

    # Parse true k16 votes ("True k16       :   0xd55e  (votes: 1, rank: #37424)")
    votes_true = 0
    m = re.search(r'True k16\s*:\s*0x[0-9a-fA-F]+\s*\(votes:\s*(\d+)', stdout)
    if m:
        votes_true = int(m.group(1))

    # Parse match
    phase1_ok = "Match: YES" in stdout

    # Parse rank
    rank_true = -1
    m = re.search(r'rank:\s*#(\d+)', stdout)
    if m:
        rank_true = int(m.group(1))

    # Parse num groups
    num_groups = 0
    m = re.search(r'Total groups:\s*(\d+)', stdout)
    if m:
        num_groups = int(m.group(1))

    return phase1_ok, scan_time, survivors, votes_best, votes_true, rank_true, num_groups


def run_phase2(key_hex: str, threads: int, solver: str):
    """
    Run Phase 2 recovery.
    Returns (success, sat_time_sec, recovered_key_hex).
    """
    python_exe = find_python()
    t0 = time.time()
    result = subprocess.run(
        [python_exe, str(SAT_PY),
         "--key", key_hex,
         "--solver", solver,
         "--workers", str(threads)],
        capture_output=True, text=True, cwd=str(SCRIPT_DIR),
        timeout=3600  # 1h max
    )
    wall_time = time.time() - t0

    stdout = result.stdout

    # Parse recovered key ("KEY      : 0x5CF29EAB2805D55E")
    recovered_key = None
    m = re.search(r'KEY\s*:\s*0x([0-9a-fA-F]+)', stdout)
    if m:
        recovered_key = m.group(1).upper()

    # Check if it matches ("[+] MATCH:")
    success = "MATCH:" in stdout and "RESULT: KEY RECOVERED" in stdout

    # Parse Phase 2 time ("Phase 2      :    774.3s")
    sat_time = wall_time
    m = re.search(r'Phase 2\s*:\s*([\d.]+)s', stdout)
    if m:
        sat_time = float(m.group(1))

    phase2_stage = ""
    phase2_step = ""
    phase2_group = -1
    phase2_group_size = -1
    phase2_group_votes = -1
    phase2_singletons_tested = -1
    phase2_prefixes_tried = -1
    m = re.search(r'PHASE2_META\s+stage=(\S+)\s+step=(\S+)\s+group=(\d+)\s+n=(\d+)\s+votes=(\d+)', stdout)
    if m:
        phase2_stage = m.group(1)
        phase2_step = m.group(2)
        phase2_group = int(m.group(3))
        phase2_group_size = int(m.group(4))
        phase2_group_votes = int(m.group(5))

    m = re.search(r'Singletons tested:\s*(\d+)', stdout)
    if m:
        phase2_singletons_tested = int(m.group(1))

    m = re.search(r'Prefixes tried in winning group:\s*(\d+)', stdout)
    if m:
        phase2_prefixes_tried = int(m.group(1))

    return (success, sat_time, wall_time, recovered_key,
            phase2_stage, phase2_step, phase2_group,
            phase2_group_size, phase2_group_votes,
            phase2_singletons_tested, phase2_prefixes_tried)


def run_single_key(key: int, phase1_threads: int, phase2_threads: int,
                   solver: str, trial: int, total: int,
                   phase1_only: bool = False, phase1_backend: str = "cpu",
                   skip_phase2_if_absent: bool = False):
    """Run full attack on one key. Returns dict of results."""
    key_hex = f"0x{key:016X}"
    print(f"\n{'='*64}")
    print(f"  Trial {trial}/{total}  Key: {key_hex}")
    print(f"{'='*64}")

    # Phase 1
    print(f"  [Phase 1] Scanning...", flush=True)
    p1_ok, scan_time, survivors, votes_best, votes_true, rank_true, num_groups = \
        run_phase1(key_hex, phase1_threads, backend=phase1_backend)
    p1_present = (votes_true > 0)
    p1_status = p1_present if phase1_only else p1_ok
    print(f"  [Phase 1] {scan_time:.1f}s  survivors={survivors}  "
          f"votes_true={votes_true}  present={'YES' if p1_present else 'NO'}  rank=#{rank_true}  "
          f"{'OK' if p1_status else 'FAIL'}")

    # Phase 2
    p2_ok = False
    sat_time = 0.0
    sat_wall = 0.0
    recovered = ""
    phase2_stage = ""
    phase2_step = ""
    phase2_group = -1
    phase2_group_size = -1
    phase2_group_votes = -1
    phase2_singletons_tested = -1
    phase2_prefixes_tried = -1

    if phase1_only:
        print(f"  [Phase 2] Skipped (--phase1-only)")
        p2_ok = False
        sat_time = 0.0
        sat_wall = 0.0
        recovered = ""
    elif skip_phase2_if_absent and not p1_present:
        print(f"  [Phase 2] Skipped (oracle: no true phase-1 signal)")
        p2_ok = False
        sat_time = 0.0
        sat_wall = 0.0
        recovered = ""
    elif DATA_FILE.exists():
        print(f"  [Phase 2] Recovering remaining key bits...", flush=True)
        try:
            (p2_ok, sat_time, sat_wall, recovered,
             phase2_stage, phase2_step, phase2_group,
             phase2_group_size, phase2_group_votes,
             phase2_singletons_tested, phase2_prefixes_tried) = run_phase2(key_hex, phase2_threads, solver)
        except subprocess.TimeoutExpired:
            print(f"  [Phase 2] TIMEOUT (1h)")
            p2_ok = False
            sat_time = 3600
            sat_wall = 3600
            recovered = ""
        print(f"  [Phase 2] {sat_time:.1f}s  "
              f"{'SUCCESS' if p2_ok else 'FAIL'}  "
              f"recovered={recovered or 'None'}")
        if phase2_step == 'singleton' and phase2_singletons_tested >= 0:
            print(f"             singletons_tested={phase2_singletons_tested}  prefixes_tried={phase2_prefixes_tried}")
    else:
        print(f"  [Phase 2] Skipped (no data file)")

    total_time = scan_time + sat_wall
    # In phase1-only mode, success should reflect theoretical usability of
    # Phase 1 output: whether the true group exists at all (votes_true > 0).
    overall_ok = p1_present if phase1_only else p2_ok

    print(f"  Total: {total_time:.1f}s  {'SUCCESS' if overall_ok else 'FAIL'}")

    return {
        "trial": trial,
        "key": key_hex,
        "success": overall_ok,
        "phase1_ok": p1_ok,
        "phase2_ok": p2_ok,
        "scan_time": scan_time,
        "sat_time": sat_time,
        "sat_wall_time": sat_wall,
        "total_time": total_time,
        "survivors": survivors,
        "votes_best": votes_best,
        "votes_true": votes_true,
        "rank_true": rank_true,
        "num_groups": num_groups,
        "phase2_stage": phase2_stage,
        "phase2_step": phase2_step,
        "phase2_group": phase2_group,
        "phase2_group_size": phase2_group_size,
        "phase2_group_votes": phase2_group_votes,
        "phase2_singletons_tested": phase2_singletons_tested,
        "phase2_prefixes_tried": phase2_prefixes_tried,
        "recovered_key": recovered or "",
    }


def compute_stats(values):
    """Compute basic statistics for a list of numbers."""
    if not values:
        return {"n": 0, "mean": 0, "std": 0, "min": 0, "max": 0,
                "median": 0, "p25": 0, "p75": 0}
    n = len(values)
    s = sorted(values)
    mean = sum(s) / n
    variance = sum((x - mean) ** 2 for x in s) / n if n > 1 else 0
    std = math.sqrt(variance)
    median = s[n // 2] if n % 2 == 1 else (s[n // 2 - 1] + s[n // 2]) / 2
    p25 = s[n // 4]
    p75 = s[3 * n // 4]
    return {"n": n, "mean": mean, "std": std, "min": s[0], "max": s[-1],
            "median": median, "p25": p25, "p75": p75}


def write_summary(results, args):
    """Write summary statistics to text file and stdout."""
    n = len(results)
    successes = [r for r in results if r["success"]]
    failures = [r for r in results if not r["success"]]
    p1_failures = [r for r in results if not r["phase1_ok"]]
    p1_present = [r for r in results if r["votes_true"] > 0]
    p1_absent = [r for r in results if r["votes_true"] == 0]
    p2_oracle_skips = [r for r in results if args.skip_phase2_if_absent and r["votes_true"] == 0]

    rank_le_1 = [r for r in results if r["rank_true"] == 1]
    rank_le_10 = [r for r in results if 1 <= r["rank_true"] <= 10]
    rank_le_100 = [r for r in results if 1 <= r["rank_true"] <= 100]
    rank_le_1000 = [r for r in results if 1 <= r["rank_true"] <= 1000]

    scan_times = [r["scan_time"] for r in results]
    sat_times = [r["sat_time"] for r in successes] if not args.phase1_only else []
    total_times = [r["total_time"] for r in results]
    total_times_ok = [r["total_time"] for r in successes]
    survivors_list = [r["survivors"] for r in results]
    votes_true_list = [r["votes_true"] for r in results]

    scan_stats = compute_stats(scan_times)
    sat_stats = compute_stats(sat_times)
    total_stats = compute_stats(total_times)
    total_ok_stats = compute_stats(total_times_ok)
    surv_stats = compute_stats(survivors_list)
    vote_stats = compute_stats(votes_true_list)

    lines = []
    lines.append("=" * 64)
    lines.append("  Fixed-Point Attack Benchmark Results")
    lines.append("=" * 64)
    lines.append(f"  Keys tested:      {n}")
    lines.append(f"  Phase 1 threads:  {args.phase1_threads}")
    lines.append(f"  Phase 2 threads:  {args.phase2_threads}")
    lines.append(f"  SAT solver:       {args.solver}")
    lines.append(f"  Mode:             {'phase1-only' if args.phase1_only else 'full (phase1+phase2)'}")
    lines.append(f"  Oracle skip P2:   {'yes' if args.skip_phase2_if_absent else 'no'}")

    lines.append(f"  Phase 1 presence: {len(p1_present)}/{n} "
                 f"({100*len(p1_present)/n:.1f}%, votes_true > 0)")
    lines.append(f"  Phase 1 absent:   {len(p1_absent)}/{n} "
                 f"({100*len(p1_absent)/n:.1f}%, votes_true = 0)")
    if args.skip_phase2_if_absent and not args.phase1_only:
        lines.append(f"  Phase 2 skipped:  {len(p2_oracle_skips)}/{n} "
                     f"({100*len(p2_oracle_skips)/n:.1f}%, oracle skip on absent keys)")

    if args.phase1_only:
        lines.append(f"  Phase 1 success:  {len(successes)}/{n} "
                     f"({100*len(successes)/n:.1f}%, same as presence in phase1-only mode)")
    else:
        lines.append(f"  Success rate:     {len(successes)}/{n} "
                     f"({100*len(successes)/n:.1f}%)")
    lines.append(f"  Phase 1 top-1:    {len(rank_le_1)}/{n} "
                 f"({100*len(rank_le_1)/n:.1f}%, true k16 rank = #1)")
    lines.append(f"  Phase 1 rank<=10: {len(rank_le_10)}/{n} "
                 f"({100*len(rank_le_10)/n:.1f}%)")
    lines.append(f"  Phase 1 rank<=100:{len(rank_le_100)}/{n} "
                 f"({100*len(rank_le_100)/n:.1f}%)")
    lines.append(f"  Phase 1 rank<=1k: {len(rank_le_1000)}/{n} "
                 f"({100*len(rank_le_1000)/n:.1f}%)")
    lines.append(f"  Phase 1 non-top1: {len(p1_failures)}/{n} "
                 f"({100*len(p1_failures)/n:.1f}%, true k16 rank > #1)")
    lines.append("")
    lines.append("  Phase 1 (Scan) Timing [seconds]:")
    lines.append(f"    Mean:   {scan_stats['mean']:.1f}")
    lines.append(f"    Std:    {scan_stats['std']:.1f}")
    lines.append(f"    Min:    {scan_stats['min']:.1f}")
    lines.append(f"    Median: {scan_stats['median']:.1f}")
    lines.append(f"    Max:    {scan_stats['max']:.1f}")
    lines.append(f"    P25:    {scan_stats['p25']:.1f}")
    lines.append(f"    P75:    {scan_stats['p75']:.1f}")
    lines.append("")
    if sat_stats["n"] > 0:
        lines.append(f"  Phase 2 Timing [seconds] (successful only, n={sat_stats['n']}):")
        lines.append(f"    Mean:   {sat_stats['mean']:.1f}")
        lines.append(f"    Std:    {sat_stats['std']:.1f}")
        lines.append(f"    Min:    {sat_stats['min']:.1f}")
        lines.append(f"    Median: {sat_stats['median']:.1f}")
        lines.append(f"    Max:    {sat_stats['max']:.1f}")
        lines.append(f"    P25:    {sat_stats['p25']:.1f}")
        lines.append(f"    P75:    {sat_stats['p75']:.1f}")
        lines.append("")
    lines.append(f"  Total Time [seconds] (all keys, n={total_stats['n']}):")
    lines.append(f"    Mean:   {total_stats['mean']:.1f}")
    lines.append(f"    Std:    {total_stats['std']:.1f}")
    lines.append(f"    Min:    {total_stats['min']:.1f}")
    lines.append(f"    Median: {total_stats['median']:.1f}")
    lines.append(f"    Max:    {total_stats['max']:.1f}")
    lines.append(f"    P25:    {total_stats['p25']:.1f}")
    lines.append(f"    P75:    {total_stats['p75']:.1f}")
    if total_ok_stats["n"] > 0 and total_ok_stats["n"] < total_stats["n"]:
        lines.append(f"  Total Time [seconds] (successful only, n={total_ok_stats['n']}):")
        lines.append(f"    Mean:   {total_ok_stats['mean']:.1f}")
        lines.append(f"    Median: {total_ok_stats['median']:.1f}")
    lines.append("")
    lines.append(f"  Survivors per key:")
    lines.append(f"    Mean:   {surv_stats['mean']:.0f}")
    lines.append(f"    Min:    {surv_stats['min']}")
    lines.append(f"    Median: {surv_stats['median']:.0f}")
    lines.append(f"    Max:    {surv_stats['max']}")
    lines.append("")
    lines.append(f"  True k[0..15] votes:")
    lines.append(f"    Mean:   {vote_stats['mean']:.1f}")
    lines.append(f"    Min:    {vote_stats['min']}")
    lines.append(f"    Median: {vote_stats['median']:.1f}")
    lines.append(f"    Max:    {vote_stats['max']}")
    lines.append("")
    lines.append("=" * 64)

    text = "\n".join(lines)
    print(f"\n{text}")

    with open(TXT_FILE, "w") as f:
        f.write(text + "\n")
    print(f"\n  Summary written to: {TXT_FILE}")


def main():
    parser = argparse.ArgumentParser(
        description="Benchmark fixed-point attack on random keys")
    parser.add_argument("--num-keys", "-n", type=int, default=100,
                        help="Number of random keys to test (default: 100)")
    parser.add_argument("--threads", "-t", type=int, default=10,
                        help="Legacy shared thread count for both phases (default: 10)")
    parser.add_argument("--phase1-threads", type=int, default=None,
                        help="Phase 1 CPU threads or GPU threads-per-block (default: --threads)")
    parser.add_argument("--phase2-threads", type=int, default=None,
                        help="Phase 2 worker count (default: --threads)")
    parser.add_argument("--solver", "-s", choices=["cryptominisat", "cadical"],
                        default="cadical",
                        help="SAT solver: cryptominisat|cadical (default: cadical)")
    parser.add_argument("--seed", type=int, default=42,
                        help="Random seed for key generation (default: 42)")
    parser.add_argument("--resume", action="store_true",
                        help="Resume from existing CSV (skip already-tested keys)")
    parser.add_argument("--phase1-only", action="store_true",
                        help="Benchmark only Phase 1 (skip Phase 2)")
    parser.add_argument("--phase1-backend", choices=["cpu", "gpu"], default="cpu",
                        help="Phase 1 backend: cpu|gpu (default: cpu)")
    parser.add_argument("--skip-phase2-if-absent", action="store_true",
                        help="Benchmark-only shortcut: skip Phase 2 when votes_true = 0")
    args = parser.parse_args()

    args.phase1_threads = args.phase1_threads if args.phase1_threads is not None else args.threads
    args.phase2_threads = args.phase2_threads if args.phase2_threads is not None else args.threads

    ensure_binary(args.phase1_backend)

    # Generate random keys
    rng = random.Random(args.seed)
    keys = [rng.getrandbits(64) for _ in range(args.num_keys)]

    # Resume support: load existing results
    done_keys = set()
    existing_results = []
    if args.resume and CSV_FILE.exists():
        with open(CSV_FILE, "r") as f:
            reader = csv.DictReader(f)
            for row in reader:
                existing_results.append(row)
                done_keys.add(row["key"])
        print(f"[resume] Loaded {len(existing_results)} completed trials from {CSV_FILE}")

    # CSV setup
    fieldnames = ["trial", "key", "success", "phase1_ok", "phase2_ok",
                  "scan_time", "sat_time", "sat_wall_time", "total_time",
                  "survivors", "votes_best", "votes_true",
                  "rank_true", "num_groups", "phase2_stage", "phase2_step",
                  "phase2_group", "phase2_group_size", "phase2_group_votes",
                  "phase2_singletons_tested", "phase2_prefixes_tried",
                  "recovered_key"]

    mode = "a" if args.resume and CSV_FILE.exists() else "w"
    csv_fp = open(CSV_FILE, mode, newline="")
    writer = csv.DictWriter(csv_fp, fieldnames=fieldnames)
    if mode == "w":
        writer.writeheader()
    csv_fp.flush()

    print(f"\n{'='*64}")
    print(f"  Fixed-Point Attack Benchmark")
    print(f"{'='*64}")
    print(f"  Keys:     {args.num_keys}")
    print(f"  P1 thr.:  {args.phase1_threads}")
    print(f"  P2 thr.:  {args.phase2_threads}")
    print(f"  Solver:   {args.solver}")
    print(f"  Mode:     {'phase1-only' if args.phase1_only else 'full'}")
    print(f"  P1 back.: {args.phase1_backend}")
    print(f"  P2 skip:  {'yes' if args.skip_phase2_if_absent else 'no'}")
    print(f"  Seed:     {args.seed}")
    print(f"  Resume:   {args.resume} ({len(done_keys)} done)")
    print(f"  Output:   {CSV_FILE}")
    print(f"{'='*64}")

    results = []
    total_t0 = time.time()

    for i, key in enumerate(keys):
        trial = i + 1
        key_hex = f"0x{key:016X}"

        if key_hex in done_keys:
            print(f"  [skip] Trial {trial}: {key_hex} (already done)")
            continue

        try:
            r = run_single_key(key, args.phase1_threads, args.phase2_threads,
                               args.solver, trial, args.num_keys,
                               phase1_only=args.phase1_only,
                               phase1_backend=args.phase1_backend,
                               skip_phase2_if_absent=args.skip_phase2_if_absent)
            writer.writerow(r)
            csv_fp.flush()
            results.append(r)
        except subprocess.TimeoutExpired:
            print(f"  [TIMEOUT] Trial {trial}: {key_hex}")
            r = {
                "trial": trial, "key": key_hex,
                "success": False, "phase1_ok": False, "phase2_ok": False,
                "scan_time": 7200, "sat_time": 0, "sat_wall_time": 0,
                "total_time": 7200, "survivors": 0,
                "votes_best": 0, "votes_true": 0,
                "rank_true": -1, "num_groups": 0,
                "phase2_stage": "", "phase2_step": "",
                "phase2_group": -1, "phase2_group_size": -1,
                "phase2_group_votes": -1,
                "phase2_singletons_tested": -1,
                "phase2_prefixes_tried": -1,
                "recovered_key": "",
            }
            writer.writerow(r)
            csv_fp.flush()
            results.append(r)
        except Exception as e:
            print(f"  [ERROR] Trial {trial}: {key_hex}: {e}")
            r = {
                "trial": trial, "key": key_hex,
                "success": False, "phase1_ok": False, "phase2_ok": False,
                "scan_time": 0, "sat_time": 0, "sat_wall_time": 0,
                "total_time": 0, "survivors": 0,
                "votes_best": 0, "votes_true": 0,
                "rank_true": -1, "num_groups": 0,
                "phase2_stage": "", "phase2_step": "",
                "phase2_group": -1, "phase2_group_size": -1,
                "phase2_group_votes": -1,
                "phase2_singletons_tested": -1,
                "phase2_prefixes_tried": -1,
                "recovered_key": "",
            }
            writer.writerow(r)
            csv_fp.flush()
            results.append(r)

        # Progress
        elapsed = time.time() - total_t0
        done_now = len(results)
        remaining = args.num_keys - len(done_keys) - done_now
        if done_now > 0:
            avg = elapsed / done_now
            eta = avg * remaining
            print(f"\n  Progress: {done_now + len(done_keys)}/{args.num_keys}  "
                  f"Elapsed: {elapsed:.0f}s  ETA: {eta:.0f}s ({eta/60:.0f}m)")

    csv_fp.close()

    # Reload all results for summary (including resumed ones)
    all_results = []
    with open(CSV_FILE, "r") as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Convert types
            row["success"] = row["success"] == "True"
            row["phase1_ok"] = row["phase1_ok"] == "True"
            row["phase2_ok"] = row["phase2_ok"] == "True"
            row["scan_time"] = float(row["scan_time"])
            row["sat_time"] = float(row["sat_time"])
            row["sat_wall_time"] = float(row["sat_wall_time"])
            row["total_time"] = float(row["total_time"])
            row["survivors"] = int(row["survivors"])
            row["votes_best"] = int(row["votes_best"])
            row["votes_true"] = int(row["votes_true"])
            row["rank_true"] = int(row["rank_true"])
            row["num_groups"] = int(row["num_groups"])
            row["phase2_group"] = int(row["phase2_group"])
            row["phase2_group_size"] = int(row["phase2_group_size"])
            row["phase2_group_votes"] = int(row["phase2_group_votes"])
            all_results.append(row)

    write_summary(all_results, args)

    total_elapsed = time.time() - total_t0
    print(f"\n  Benchmark completed in {total_elapsed:.0f}s ({total_elapsed/60:.1f}m)")


if __name__ == "__main__":
    main()
