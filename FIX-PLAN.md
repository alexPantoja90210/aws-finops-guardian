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

## Slice 3: the claims  (done)

**The Terraform work turned out not to exist.** `ManagedBy = "terraform"` has
been set since IA-7 as `default_tags` on both `provider "aws"` blocks. It was
planned here because the plan was written before `infra/versions.tf` was read.

Three predictions were registered before checking the account and all three
failed, recorded on IA-199. The one that mattered: `i-0318219b00fc4df65` was
expected to carry the tag, which would have made the IA-199 detector
inadequate. It carries none, and the detector finds exactly the right two
resources on the live account.

What the slice actually was:

| Claim, before | Issue | Claim, after |
| --- | --- | --- |
| "a zero-spend budget **guards** the account" | IA-204 | it notifies, it has no power to stop anything, and the brake was declined for a written reason |
| "**the whole stack** is defined in Terraform" | IA-199 | everything this project manages, and a clean plan is silent about the rest |
| "produces an **AI** executive brief" | IA-209 | generated from a template. `build_brief` is f-strings and there is no model in the repository |
| "**v1 complete**" | IA-209 | what is complete, and a table of what is not |

Plus two sections the README did not have: **what is detected and by which
mechanism**, with a column for what each mechanism *cannot* catch, and **the
invariant suite**, which is now the repository's main piece of evidence and
went unmentioned.

### The decision recorded on IA-204

Notify-only. An AWS Budgets Action would give the account a real brake and was
declined: it puts a role in the account that can stop instances, and the
strongest sentence this project can make is that it cannot change your account.
The saving at stake is 2.56 USD a month.

**That decision carries a condition for revisiting it**, because a decision
without one is just a thing that gets forgotten: when the account holds any
resource outside the free tier, or when the gross forecast exceeds the budget
by more than an agreed multiple.

The failure was never the missing brake. It was an alert that repeated
identically with no resource, no amount and no action. That is IA-211, and it
is the part that would actually have changed the outcome.

### Raised during the slice

- **IA-209**, the two README claims above, under rule 2 rather than corrected
  in silence. Fixing them quietly would have reduced the defect count by the
  two most uncomfortable instances in the set, which is the bias rule 2 exists
  to prevent.
- **IA-210**, the CI check comparing state against the account, for the drift
  the tag structurally cannot catch.
- **IA-211**, the alert redesign.

## Slice 3b: the claim that the whole file was making  (done)

Raised as IA-213 after slices 1 to 3 had shipped, which is worth noting: the
three slices above corrected sentences inside a document whose overall claim
was false. Every individual statement could have been made true and the file
would still have described a service that does not exist.

`guardian.py` is not on the instance, `boto3` is not installed there, nothing
schedules it, no `report.json` has ever existed on it, nginx is `inactive`, and
Cost Explorer counted 12 API requests in August and 2 in September against the
~30 a month a daily run would make. August had 3.07 EC2 compute hours in total.

The README now leads with it, carries an **Is it deployed** section with the
evidence, splits Phase 5 into CI (done) and scheduling (never built), and marks
Phases 2, 3 and 4 as written and tested rather than running.

**Phase 12 was added and is a precondition for any deployment work.** A
liveness check that refuses stale output. Deploying without it would recreate
IA-213 in a different shape: something would run once, stop, and nothing would
say so.

## Slice 4: mutations  (done)

```
python prove_it_can_fail.py   ->  all 11 mutations were caught
```

Eleven, one per defect fixed in slices 2 and 3, each naming the invariants that
must go red for it. A mutation that reddens the suite for an unrelated reason
proves nothing.

One targets `fakes.py` rather than the product. If the fakes stop refusing
filters they do not model, several invariants keep passing while testing
nothing, so a broken fake has to be caught too.

### The harness has two controls of its own

The argument that a suite seen only passing might be unable to fail applies to
the harness as much as to the suite. Both were run deliberately before
committing:

- **A moved anchor.** The `money()` anchor was altered on purpose. The harness
  printed `SKIP  the anchor has moved, so this proves nothing` and exited
  non-zero, rather than passing quietly on a rule it had not tested.
- **A mutation that changes nothing.** A planted mutation editing only a
  comment produced `the suite stayed green` and exit 1. The harness reports its
  own failure to prove anything.

### Three invariants the harness forced into existence

Written before it ran, because three mutations had nothing to catch them:

- an instance whose stop time AWS does not report is still reported, with the
  duration stated as unknown
- the undeclared **volume**, as distinct from the undeclared instance
- a canary on the detector count, labelled a canary in its own docstring
  because nothing here can prove `DETECTORS` lists every detector without a
  second list to compare against, which is the defect IA-203 was about

44 invariants now, from 41.

### CI

The workflow runs the harness after the suite. After, not before: proving a
suite can fail while it is already failing proves nothing. The whole run takes
about a second, because nothing here touches a network or an account.

## What is left

Nothing in this plan. What remains is on its own issues: IA-199's instance,
IA-209's acceptance, IA-210, IA-211, IA-213's deployment (blocked on Phase 12,
the liveness check) and IA-215.
