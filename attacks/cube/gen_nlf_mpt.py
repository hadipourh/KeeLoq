#!/usr/bin/env python3
"""
Generate the monomial prediction table (MPT) and CNF constraints
for the KeeLoq NLF (5-bit to 1-bit Boolean function).

NLF truth table is defined by the constant 0x3A5C742E:
  For 5-bit input i = (x4,x3,x2,x1,x0), output = bit i of 0x3A5C742E

In KeeLoq encryption:
  nlf_input = (L[31]<<4) | (L[26]<<3) | (L[20]<<2) | (L[9]<<1) | L[1]
  So: x4=L[31], x3=L[26], x2=L[20], x1=L[9], x0=L[1]
"""

NLF_CONSTANT = 0x3A5C742E

# ---- Step 1: Truth table ----
tt = [(NLF_CONSTANT >> i) & 1 for i in range(32)]

print("=== NLF Truth Table ===")
for i in range(32):
    bits = format(i, '05b')
    print(f"  NLF({bits[0]},{bits[1]},{bits[2]},{bits[3]},{bits[4]}) = {tt[i]}")

# ---- Step 2: Compute ANF via Mobius transform ----
anf = tt[:]
for i in range(5):
    for j in range(32):
        if j & (1 << i):
            anf[j] ^= anf[j ^ (1 << i)]

var_names = ['x0', 'x1', 'x2', 'x3', 'x4']
terms = []
for u in range(32):
    if anf[u]:
        if u == 0:
            terms.append('1')
        else:
            t = '*'.join(var_names[i] for i in range(5) if (u >> i) & 1)
            terms.append(t)

print(f"\n=== Algebraic Normal Form ===")
print(f"NLF(x) = {' + '.join(terms)}")
print(f"Algebraic degree = {max(bin(u).count('1') for u in range(32) if anf[u])}")

# ---- Step 3: Monomial Prediction Table ----
# For a 5->1 function f:
#   MPT has rows indexed by u in {0,1}^5 and columns by v in {0,1}
#   MPT[u][v] = 1 iff x^u appears in ANF of f^v
#   v=0: f^0 = 1, so only u=(0,0,0,0,0) is present
#   v=1: f^1 = f(x), so check ANF

print(f"\n=== Monomial Prediction Table ===")
print(f"{'u (u4 u3 u2 u1 u0)':>22} | v=0 | v=1")
print("-" * 38)

valid_transitions = []
for u in range(32):
    v0 = 1 if u == 0 else 0
    v1 = anf[u]
    ubits = format(u, '05b')
    print(f"  ({ubits[0]}  {ubits[1]}  {ubits[2]}  {ubits[3]}  {ubits[4]})      |  {v0}  |  {v1}")
    if v0:
        valid_transitions.append((u, 0))
    if v1:
        valid_transitions.append((u, 1))

print(f"\nValid transitions: {len(valid_transitions)} / 64")

# ---- Step 4: Try SboxAnalyzer ----
print(f"\n=== Trying SboxAnalyzer ===")
try:
    from sboxanalyzer import SboxAnalyzer
    sa = SboxAnalyzer(tt)
    print("SboxAnalyzer object created.")
    cnf, milp, cp = sa.minimized_integral_constraints()
    print(f"\nCNF constraints:\n{cnf}")
    print(f"\nMILP constraints:\n{milp}")
    print(f"\nCP constraints:\n{cp}")
except Exception as e:
    print(f"SboxAnalyzer failed: {type(e).__name__}: {e}")
    print("This is expected if SageMath is not installed.")
    print("We will generate CNF constraints manually below.")

# ---- Step 5: Generate CNF manually ----
# We need to encode: (u0,u1,u2,u3,u4,v) must be a valid MPT transition
# Invalid transitions: those (u,v) where MPT[u][v] = 0
# For each invalid (u,v), add a clause blocking it

# Valid (u,v) pairs:
valid_set = set()
for u in range(32):
    # v=0: valid only if u==0
    if u == 0:
        valid_set.add((0, 0))
    # v=1: valid if anf[u] == 1
    if anf[u]:
        valid_set.add((u, 1))

# All invalid (u,v) pairs
invalid = []
for u in range(32):
    for v in range(2):
        if (u, v) not in valid_set:
            invalid.append((u, v))

print(f"\n=== Manual CNF Generation ===")
print(f"Invalid transitions to block: {len(invalid)}")

# For each invalid (u, v), we need a clause that prevents this assignment.
# Variables: u0, u1, u2, u3, u4, v (all binary)
# If u bit i is 1, the literal is NOT(u_i); if 0, literal is u_i
# Similarly for v
# The clause says: at least one of these literals must be true (i.e., the assignment is different)

clauses = []
for (u, v) in invalid:
    clause = []
    for i in range(5):
        if (u >> i) & 1:
            clause.append(-(i+1))  # NOT u_i  (variables 1..5 are u0..u4)
        else:
            clause.append(i+1)     # u_i
    if v == 1:
        clause.append(-6)          # NOT v  (variable 6 is v)
    else:
        clause.append(6)           # v
    clauses.append(clause)

print(f"Number of raw clauses: {len(clauses)}")

# Print clauses in human readable form
var_labels = ['u0', 'u1', 'u2', 'u3', 'u4', 'v']
print("\nClauses (u0=1, u1=2, u2=3, u3=4, u4=5, v=6):")
for i, cl in enumerate(clauses):
    lits = []
    for l in cl:
        if l > 0:
            lits.append(var_labels[l-1])
        else:
            lits.append(f'~{var_labels[-l-1]}')
    print(f"  C{i:02d}: ({' | '.join(lits)})")

print(f"\nTotal clauses for NLF MPT: {len(clauses)}")
print(f"\nThese {len(clauses)} clauses over 6 variables (u0..u4, v) encode the MPT.")
print("In the SAT model, each NLF instance uses 6 fresh indicator variables.")
