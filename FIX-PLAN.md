# The fix, sliced

Six defects were found on 29 September 2026 and recorded as IA-199 to IA-204.
This file says how they get closed and in what order, so that the order is a
decision on the record rather than whatever happened first.

## Slice 1: an invariant suite, written before the fixes  (done, 3871774)

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

## Slice 2: make it green  (done)

`all 41 invariants hold`. Nine were added during the slice, for the detector
list and for the dashboard, which is the last place an absence could still be
painted as a zero.

| Issue | What changed |
| --- | --- |
| IA-202 | `forecast()` sends a `RECORD_TYPE` filter excluding Credit and Refund, and returns `cost_view` naming what it measured. The report and the page print it. |
| IA-203 | `BUDGET = 5.00` is gone. The limit is read from the budget by name. When it cannot be read there is no verdict, and the reason says which budgets were seen. |
| IA-206 | A third verdict, `UNKNOWN`. A missing measurement is never rendered as a zero and never as OK, in the terminal report or on the page. |
| IA-201 | Identity comes from the IMDSv2 instance-identity document, which also supplies the account id, so neither needs an IAM permission the role lacks. `SELF_NAME` is gone. With no identity, nothing is excluded and the report says so. |
| IA-200 | `idle_attached_volumes()`: volumes on instances stopped longer than seven days. An instance whose stop time AWS does not report is included with the duration stated as unknown, rather than skipped. |
| IA-199 | `undeclared_resources()`: instances and volumes with no `ManagedBy=terraform` tag, reported in their own section because they are not waste. The tag itself is still to be added in Terraform, slice 3. |

`budgets:DescribeBudgets` and `sts:GetCallerIdentity` were already in both the
Allow and the `NotAction` Deny, so this slice needed no change to the IAM
policy and the read-only guarantee is untouched.

### On the fixture account, the Guardian now says

```
Forecast   MTD $3.44   EOM $3.56   Budget $1.00   [OVER]
Cost view  gross (RECORD_TYPE Credit and Refund excluded)

WASTE FOUND: 4 item(s)  ->  $2.56/mo on the floor
UNDECLARED: 2 resource(s) with no ManagedBy=terraform tag
Health score: 55/100
```

against `MTD $0.00 ... [OK]` and `Clean account.` before.

### One defect committed inside the fix, and caught

`money(None)` was given a guard so an unreadable figure would render as
`unknown`. Probing the suite by breaking that guard on purpose left all forty
invariants green: no other invariant reached the branch, because the UNKNOWN
path never calls it. **A guard with nothing that would notice its removal is
an instruction with no mechanism**, which is the defect this repository is
about, committed in the middle of fixing it.

It was found by probing rather than by reading, which is the argument for
slice 4 in one paragraph. An invariant now covers it, and asserts that
`None` and `0` render differently.

### What a green suite here does and does not mean

It means the logic behaves as specified against fixtures. It does not mean
the account behaves as the fixtures describe. Two confirming runs against the
real account are still open, both recorded on their issues: the pair of
`get-cost-and-usage` calls on IA-202, and a real run of the Guardian once the
`ManagedBy` tag exists.

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

Not before slice 2, and slice 2 is done, so this is now the next thing worth
doing. The ad hoc probes run during slice 2 already found one untested guard,
which is what a real harness would do systematically instead of by hand.
