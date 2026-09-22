# Fixed-Point Success Model and Implementation Limits

This note explains the full-codebook fixed-point attack and distinguishes its theoretical search coverage from the current implementation. Commands and benchmark details are in [README.md](README.md).

## Setup and Phase 1

For a fixed key, let $F=E_{64}(K,\cdot)$ be KeeLoq's 64-round core. Full encryption is $E_{528}=E_{16}\circ F^8$. The heuristic models **$F$**, not $F^8$, as a uniformly random permutation.

The attack assumes all $2^{32}$ plaintext–ciphertext pairs. The supplied scanners generate them from a known test key; their timings exclude real-world acquisition.

For each pair $(S,C)$, test $C[0..15]=S[16..31]$. For a survivor, the feedback bits in $C[16..31]$ determine one low-key candidate through 16 rounds of peeling. There is **no $2^{16}$ key-guess loop per plaintext**.

Group survivors by their peeled value $k_{16}$. For the true low key,

$$\mathcal G_{k_{16}^*}=\{S:E_{16}(k_{16}^*,S)=E_{528}(K,S)\}=\{S:F^8(S)=S\}.$$

Invertibility of $E_{16}$ gives the equality. The true group contains exactly the true fixed points, with no extra noise votes. Wrong bins may still receive more votes, so ranking guides search order rather than deciding recovery.

## Fixed-Point Distribution

A state is fixed by $F^8$ exactly when its $F$-cycle length divides 8. For a large uniform random permutation, the small-cycle counts are approximately independent:

$$X_d\approx\operatorname{Poisson}(1/d),\qquad d\in\{1,2,4,8\}.$$

The modeled fixed-point count is $m=X_1+2X_2+4X_4+8X_8$, with mean 4 and variance 15. These moments are also exact for a uniform permutation on $2^{32}$ elements; the independent Poisson description of the full distribution is an approximation.

In that approximation,

$$\Pr(m=0)\approx e^{-15/8},\qquad \Pr(m\geq1)\approx1-e^{-15/8}\approx84.7\%.$$

Exactly one fixed point requires $X_1=1$ and $X_2=X_4=X_8=0$, so

$$\Pr(m=1)\approx e^{-15/8}\approx15.3\%,\qquad \Pr(m\geq2)\approx1-2e^{-15/8}\approx69.3\%.$$

These are heuristic predictions for KeeLoq, not proven probabilities over its keys.

## Phase 2

For each survivor compute $M_{16}=E_{16}(k_{16},S)$. In the true group, $F$ permutes the group's states, giving

$$E_{48}(k[16..63],M_{16,i})=F(S_i)=S_{\sigma(i)}.$$

### Sweep A: Groups with at Least Two Candidates

For a group of size $n\geq2$, fix source indices 0 and 1 and try all $n^2$ target pairs $(b,d)$:

$$E_{48}(k[16..63],M_{16,0})=S_b,\qquad E_{48}(k[16..63],M_{16,1})=S_d.$$

The correct successor pair is among these hypotheses for the true group. An idealized independent-constraint model predicts about $2^{48-64}=2^{-16}$ solutions for a wrong hypothesis. Most wrong hypotheses are therefore expected to be UNSAT; this does **not** mean all are UNSAT or equally fast.

Returned keys are checked against the group's full-round pairs and up to 20 additional pairs sampled from Phase 1 output. Failed candidates are blocked before another model is tried. Those sampled pairs should not be treated as 640 independently guaranteed filtering bits.

**Implementation limit:** `try_pair_sat(..., max_enum=100)` checks at most 100 SAT models for each target pair, and `_try_directed_pairs()` uses this default. All target pairs are covered, but not necessarily all SAT models. Unconditional completeness of Sweep A would require exhaustive model enumeration. There is no CLI override for this cap.

The active solver is PySAT `cadical153`. The accepted `--solver cryptominisat` option does not switch the current recovery backend.

### Sweep B: Singleton Groups

When Sweep A returns no verified key, the code processes singleton groups. If the true group is a singleton, its unique state is on a 1-cycle, and $E_{48}(k[16..63],M_{16,0})=S_0$.

The first 16 feedback bits are free; the remaining 32 are fixed by the target output. Each of the $2^{16}$ prefixes reconstructs one 48-bit suffix. This is constructive enumeration, not SAT-model enumeration. Each candidate is checked against the sampled full-round pairs.

The program first attempts a CUDA prefilter over all `(singleton group, prefix16)` combinations, testing two verification pairs. The CPU checks surviving candidates against the full verification set. If unavailable, a native C helper or Python fallback searches the same singleton completions.

Sweep B also runs for absent keys ($m=0$), and may run after a Sweep A failure caused by its model cap. Reaching Sweep B does not prove that $m=1$.

## Success and Work

For the ideal exhaustive recovery procedure, the modeled end-to-end probability equals the presence probability, approximately 84.7%. For the program, that is a prediction supported by the experiment below, subject to the SAT-model cap, resource limits, and verification assumptions.

| Component | Work |
|---|---|
| Phase 1 benchmark scan | $2^{32}$ full encryptions, a constant-time filter per record, and a 16-round peel for each survivor |
| Phase 1 postprocessing | About $2^{16}$ survivors; histogram grouping and output |
| Sweep A, group size $n$ | Up to $n^2$ SAT instances, each checking at most 100 models in the current code |
| Sweep A, all false groups | About $2^{16}(2-e^{-1})\approx2^{16.7}$ instances under the Poisson(1) bin model; SAT cost is instance-dependent |
| Sweep B, singleton group | $2^{16}$ constructive completions plus verification |
| Sweep B, conditional on a true singleton | About $2^{16}(1+2^{15}/e)\approx2^{29.6}$ completions when the true singleton is uniformly placed among false singletons |

Completion counts are not full-encryption counts: each completion reconstructs 48 rounds and must also be verified. The CPU fallback encrypts at least the first verification plaintext for each tested candidate. GPU prefiltering changes execution cost, not the candidate-space definition.

The benchmark driver imposes a two-hour Phase 1 timeout and a one-hour Phase 2 timeout. A timed-out run is not an exhaustive experiment.

## Recorded Validation

The committed [CSV](../../benchmarks/fixedpoint_benchmark.csv), [summary](../../benchmarks/fixedpoint_benchmark.txt), and [hardware record](../../benchmarks/gpu_env.txt) describe 100 keys generated with seed 42, using RTX PRO 6000 Blackwell GPU Phase 1 and 192 CPU workers for Phase 2:

- 85 keys had a true Phase 1 signal; all 85 were recovered.
- The 15 failures were precisely the keys with no true fixed point.
- 74 recoveries finished in Sweep A and 11 in Sweep B.
- Successful Phase 2 times had mean 6.0 seconds, median 3.3 seconds, and maximum 17.7 seconds.
- Successful `total_time` had mean 6.2 seconds and median 3.5 seconds.

`total_time` adds the reported Phase 1 scan time to Phase 2 process wall time; it excludes Phase 1 setup/output overhead and codebook acquisition. Scan times are printed to one decimal place, so `0.0` is a rounded value. Earlier H100 scalar-kernel measurements in the README are historical, not the current benchmark platform.
