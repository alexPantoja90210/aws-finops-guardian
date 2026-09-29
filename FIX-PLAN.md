# The fix, sliced

Six defects were found on 29 September 2026 and recorded as IA-199 to IA-204.
This file says how they get closed and in what order, so that the order is a
decision on the record rather than whatever happened first.

## Slice 1: an invariant suite, written before the fixes

`test_invariants.py` and `fakes.py`.

Every one of the six issues asks for a control, and before this slice there
was nowhere to put one: the repository had no test of any kind, and CI ran
`py_compile` and printed a tick. Every defect recorded in IA-199 to IA-204
compiles cleanly, so that tick was never evidence of anything.

The suite is written as statements of what the Guardian **must** do, not as a
description of what it does. Running it today is therefore the reproduction
of all six bugs, in one command, with no account and no spend:

```
python test_invariants.py     ->  16 of 32 invariants do not hold
```

The sixteen map one to one onto the issues:

| Issue | Red invariants |
| --- | --- |
| IA-199 undeclared resources | 2 |
| IA-200 detectors that cannot fire | 5 |
| IA-201 self-exclusion by name | 3 |
| IA-202 credit-blind forecast | 2 |
| IA-203 threshold in two places | 3 |
| found while writing the suite | 1 |

The other sixteen are green and must stay green: five controls on the fakes,
eight statements of behaviour the Guardian already gets right, and three
fixture facts.

### Why the fakes are written the way they are

**A fake that ignores a filter cannot test code that relies on one.** Both
broken detectors are broken *in their filter*. A fake that returned
everything regardless would have made them look correct. So the fakes
implement filter semantics, and raise `UnsupportedFilter` on a filter they do
not model rather than quietly returning everything.

**A fake that cannot tell two cases apart cannot test the difference.** The
Cost Explorer fake models credits as separate records, because gross against
net is the whole of IA-202.

Five of the thirty-two invariants are controls on the fakes themselves. If
the fakes are wrong, nothing else in the file means anything.

### What the suite demonstrates about IA-202

`forecast()` run against the September fixture, with the clock frozen at
29 September 2026:

```
mtd              0.0
projected_eom    0.0
budget           5.0
status           OK
data_ok          True
```

A confident OK, on a month where AWS Budgets reports 343.90% over.

Note precisely what this does and does not establish. **It establishes that
the code is credit-blind**, which is a fact about the code: it passes no
`Filter`, so it reports whatever the net view says. It does **not** establish
that this account's credits absorb the whole bill; the fixture encodes that
as an assumption. The confirming run for the second half is still the pair of
`get-cost-and-usage` calls recorded on IA-202.

### CI

The workflow now runs the suite, and therefore fails. That is the correct
state. The repository contains six recorded, reproduced, unfixed defects, and
a green badge over them would be exactly the defect the portfolio is about.

## Slice 2: make it green

In this order, because each one is a prerequisite for trusting the next.

1. **IA-202**, the cost view. Everything downstream reads this number.
2. **IA-203**, the threshold, read from the budget rather than restated.
3. **IA-201**, identity from IMDSv2 rather than a Name tag.
4. **IA-200**, the third detector: EBS attached to a long-stopped instance.
5. **IA-199**, the fourth detector: resources with no `ManagedBy` tag, plus
   the tag itself in Terraform.

## Slice 3: the claims, and the account

- The README sentences that IA-199 and IA-204 are about.
- The decision on actuation from IA-204, written down whichever way it goes.
- `terraform import` or destroy-by-plan for the untracked instance.
- Snapshot before anything is terminated: `DeleteOnTermination` is true on all
  four root volumes.

## Slice 4: mutations

`prove_it_can_fail.py`, in the shape the local RAG lab uses: break the code on
purpose in a throwaway copy, require the suite to go red, and require the
invariants that should catch each break to be the ones that do.

Not before slice 2. There is no point proving a suite can fail while sixteen
of its invariants are already failing.
