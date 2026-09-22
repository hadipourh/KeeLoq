# Complete Mathematical Analysis of End-to-End Success Probability

## Setup

Let $K \in \{0,1\}^{64}$ be the target key. Define $F = E_{64}(K, \cdot) : \{0,1\}^{32} \to \{0,1\}^{32}$, the 64-round KeeLoq encryption under $K$. We model $F$ as a uniformly random permutation of $\{0,1\}^{32}$.

## Phase 1: Fixed-Point Detection

**Decomposition.** KeeLoq's 528 rounds decompose as $E_{528} = E_{16} \circ F^8$, since each $F$ covers 64 rounds and $8 \times 64 + 16 = 528$.

**Goal.** Find $S \in \{0,1\}^{32}$ such that $F^8(S) = S$, i.e., $S$ lies on an $F$-cycle of length $d \mid 8$.

**Scan.** Evaluate $E_{528}(K, S)$ for all $2^{32}$ plaintexts $S$:
$$E_{528}(K, S) = E_{16}(K, F^8(S))$$
If $F^8(S) = S$, then $E_{528}(K, S) = E_{16}(K, S)$. Since $E_{16}$ only depends on $k[0..15]$, we can guess $k[0..15]$ (16-bit exhaustive search) and check:
$$E_{16}(k[0..15], S) \stackrel{?}{=} E_{528}(K, S)$$
A match occurs iff $k[0..15]$ is correct **and** $F^8(S) = S$.

**Output.** For each guessed $k_{16} \in \{0,1\}^{16}$, Phase 1 produces a **group**: the set of candidate fixed points $\mathcal{G}_{k_{16}} = \{S : E_{16}(k_{16}, S) = E_{528}(K, S)\}$.

For the **correct** $k_{16}^*$, $\mathcal{G}_{k_{16}^*}$ contains exactly the true fixed points of $F^8$. For incorrect $k_{16}$, $\mathcal{G}_{k_{16}}$ contains only spurious matches.

## Fixed-Point Count Distribution

For a random permutation $F$ on $\{0,1\}^{32}$, the number of elements on cycles of length $d$ follows:

$$d \cdot X_d, \quad X_d \sim \text{Poisson}(1/d)$$

independently for each $d$. The number of fixed points of $F^8$ (elements on cycles of length $d \mid 8$) is:

$$m = \sum_{d \in \{1,2,4,8\}} d \cdot X_d$$

**Moments:**
$$\mathbb{E}[m] = \sum_{d \mid 8} d \cdot \frac{1}{d} = 4$$
$$\text{Var}[m] = \sum_{d \mid 8} d^2 \cdot \frac{1}{d} = 1 + 2 + 4 + 8 = 15$$

**Presence probability** ($m \geq 1$):
$$P(m \geq 1) = 1 - P(m = 0) = 1 - \prod_{d \mid 8} P(X_d = 0) = 1 - \prod_{d \mid 8} e^{-1/d} = 1 - e^{-(1 + 1/2 + 1/4 + 1/8)} = 1 - e^{-15/8}$$

$$\boxed{P(m \geq 1) = 1 - e^{-15/8} \approx 84.7\%}$$

## Phase 2: Recovery of $k[16..63]$

Given the true group $\mathcal{G}_{k_{16}^*}$ with $m = |\mathcal{G}_{k_{16}^*}|$ candidates, each candidate $(S_i, C_i, M_{16,i})$ satisfies:

$$E_{48}(k[16..63], M_{16,i}) = F(S_i) = S_{\sigma(i)}$$

where $\sigma$ is the $F$-successor permutation within the group.

Phase 2 processes groups in two sequential sweeps:

### Sweep A: Directed-Pair Sweep (all groups with $n \geq 2$)

For each group with $|\mathcal{G}| \geq 2$ candidates, fix source indices 0 and 1, and try all $n^2$ target combinations $(b, d)$:
$$E_{48}(k[16..63], M_{16,0}) = S_b \quad \land \quad E_{48}(k[16..63], M_{16,1}) = S_d$$

- **True group ($m \geq 2$):** The correct pair $(b^*, d^*) = (\sigma(0), \sigma(1))$ is guaranteed to be in the sweep. Each 2-pair SAT instance constrains 48 unknowns with 64 output bits, so has $\sim 2^{48 - 64} = 2^{-16}$ expected solutions. The true key is found with negligible false-positive probability. $\Rightarrow$ **Recovery is certain.**
- **Wrong groups:** All $n^2$ SAT instances are UNSAT (no consistent $k[16..63]$ exists), and the solver rejects each one instantly.
- **Order within Sweep A does not matter:** wrong groups cost $n^2$ fast UNSAT calls ($\sim 0.1$–$0.5$ ms each), so even at rank $\#10{,}000$, the total sweep over $\sim 17{,}000$ wrong n≥2 groups takes only a few seconds.

### Sweep B: Exact Singleton Recovery (all groups with $n = 1$, only if Sweep A found nothing)

This sweep runs only when $m = 1$ (the true group has exactly one candidate), which implies a 1-cycle: $F(S_0) = S_0$.

For each singleton group, the solver handles the relation $E_{48}(k[16..63], M_{16,0}) = S_0$ constructively rather than through SAT-model enumeration. This relation leaves exactly 16 residual degrees of freedom. We enumerate the 16 unknown feedback bits $f_0,\dots,f_{15}$ directly; the remaining feedback bits $f_{16},\dots,f_{47}$ are fixed by the output $S_0$, so each 16-bit guess reconstructs one full key candidate. Thus Sweep B still explores exactly $2^{16} = 65{,}536$ candidates, but with only bit operations and direct verification against 20 cross-verification pairs (640 bits of filtering), making false-positive probability $< 2^{-576}$.

To accelerate this exhaustive scan, the current implementation optionally uses an exact GPU prefilter: it exhaustively checks every `(singleton group, prefix16)` pair against the first two verification pairs on the GPU, then lets the CPU perform full verification on the tiny survivor set. Because the GPU helper never prunes any candidate that satisfies those first two pairs, and the CPU still verifies every survivor against the full verification set, this acceleration does not change the searched space or the success probability.

- **True singleton group ($m = 1$):** Exhaustive constructive enumeration guarantees recovery. $\Rightarrow$ **Recovery is certain.**
- **Wrong singleton groups:** Each still has an exhaustive $2^{16}$ candidate family in principle, but the GPU prefilter rejects almost all of them before CPU verification. These groups are only reached in the $m = 1$ case.
- **Why $m = 1$ implies a 1-cycle:** If $m = 1$, exactly one element sits on cycles of length $d \mid 8$. Since a cycle has $d \geq 1$ elements and only 1 is present, $d = 1$.

### Why Sweep A Before Sweep B

Wrong singleton groups each still cost about $2^{16}$ candidate checks, so if they shared the worker pool with n≥2 groups, they would clog workers and delay reaching the true group. By deferring all singletons to Sweep B:
- The common case ($m \geq 2$, $\sim 69.3\%$ of keys) completes in Sweep A alone, with no singleton overhead.
- The rare case ($m = 1$, $\sim 15.3\%$ of keys) pays the singleton cost only when necessary, and the exact GPU prefilter removes the previous heavy tail in practice.

### Case Summary

| Condition | Probability | Sweep | Recovery method | $P(\text{key recovered})$ |
|---|---|---|---|---|
| $m = 0$ | $e^{-15/8} \approx 15.3\%$ | — | impossible | 0 |
| $m = 1$ | $\leq e^{-15/8} \approx 15.3\%$ | B | singleton constructive enum | 1 |
| $m \geq 2$ | $\geq 1 - 2e^{-15/8} \approx 69.3\%$ | A | directed-pair sweep | 1 |

## End-to-End Success Probability

$$P(\text{success}) = P(m \geq 2) \cdot 1 + P(m = 1) \cdot 1 + P(m = 0) \cdot 0 = P(m \geq 1)$$

$$\boxed{P(\text{success}) = 1 - e^{-15/8} \approx 84.7\%}$$

## Complexity Summary

| Component | Cost |
|---|---|
| Phase 1 scan | $2^{32}$ encryptions × $2^{16}$ key guesses (parallelized on GPU) |
| Sweep A: wrong n≥2 group | $n^2$ UNSAT SAT calls ($\sim 0.1$–$0.5$ ms each) |
| Sweep A: true n≥2 group ($m \geq 2$) | $\leq m^2$ SAT calls (one SAT, rest UNSAT) |
| Sweep A total | $\leq 2^{16}$ groups, dominated by group enumeration |
| Sweep B: wrong singleton group | exact $2^{16}$ constructive candidates, typically filtered on GPU to almost no CPU survivors |
| Sweep B: true singleton group ($m = 1$) | exact $2^{16}$ constructive candidates, with CPU verification on GPU-prefilter survivors |
| Sweep B total | $\leq 2^{16}$ groups, only reached for $m = 1$ case |
| **Typical Phase 2 ($m \geq 2$)** | **Sweep A only: a few seconds** |
| **Rare Phase 2 ($m = 1$)** | **Sweep A plus exact Sweep B; on the H100 benchmark, hard singleton keys still finished in about 22 seconds total** |

## Empirical Validation

Two current benchmark snapshots from the repository match the theory well:

- **Phase 1 only, H100 GPU, 100 random keys:** observed presence rate $85/100 = 85.0\%$, close to the heuristic prediction $1 - e^{-15/8} \approx 84.7\%$.
- **End to end, H100 GPU Phase 1 + CPU Phase 2, 100 random keys:** observed recovery rate $85/100 = 85.0\%$, with the only failures being the 15 `votes_true = 0` cases.

This is exactly the pattern predicted by the analysis above: once a true fixed point exists, the current exhaustive Phase 2 recovers the key. In the full 100-key run, 74 successful recoveries finished in Sweep A and 11 in Sweep B, and the successful phase~2 times had mean 7.6 seconds, median 3.1 seconds, and maximum 27.9 seconds.
