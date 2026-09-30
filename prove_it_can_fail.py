"""
Prove the suite can go red.

A suite that has only ever been seen passing is indistinguishable from one
that cannot fail. `all 44 invariants hold` is a claim about the code; it is
not yet a claim about the suite. This script breaks the code on purpose, in a
throwaway copy of the tree, and asserts that the suite notices each time and
that the invariants which should catch each break are the ones that do.

A mutation that reddens the suite for some unrelated reason proves nothing, so
each one names the invariants it expects.

This is not hypothetical here. During the fix for IA-208 a guard was added to
`money()` so an unreadable figure would render as `unknown`. Breaking it on
purpose left all forty invariants green: nothing reached that branch. That was
found by four hand-run probes. This file is what finds the ones nobody thought
to probe.

It changes nothing in the working tree.

Run:  python prove_it_can_fail.py
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).parent

# (target file, name, find, replace, invariants that must go red)
MUTATIONS = [
    (
        "src/guardian.py",
        "the credit filter dropped, the IA-202 defect restored",
        '            Granularity="DAILY", Metrics=["UnblendedCost"], Filter=GROSS_ONLY)',
        '            Granularity="DAILY", Metrics=["UnblendedCost"])',
        ["the month-to-date figure is gross, so credits cannot hide spend",
         "with September's own figures the verdict is OVER"],
    ),
    (
        "src/guardian.py",
        "the budget limit read from a constant again, the IA-203 defect",
        '    if budgets is None:\n        return None, "no Budgets client was supplied"',
        '    if True:\n        return 5.00, ""',
        ["the budget limit comes from the account, not from a constant in the module",
         "with September's own figures the verdict is OVER",
         "when the limit cannot be read there is no verdict at all"],
    ),
    (
        "src/guardian.py",
        "an unreadable month reported as OK, the IA-206 defect",
        '    if not data_ok:\n        status = "UNKNOWN"',
        '    if not data_ok:\n        status = "OK"',
        ["a Cost Explorer outage does not produce an OK verdict"],
    ),
    (
        "src/guardian.py",
        "self-exclusion by Name tag again, the IA-201 defect",
        "            if self_instance_id is not None and iid == self_instance_id:",
        '            if name_of(inst) == "finops-guardian":',
        ["the Guardian excludes itself by instance id, whatever its Name tag",
         "an instance merely named finops-guardian is still reported"],
    ),
    (
        "src/guardian.py",
        "an unparseable stop time silently skipped, the IA-200 shape",
        '            if since is None:\n                stopped[inst["InstanceId"]] = None',
        "            if since is None:\n                continue",
        ["an instance whose stop time AWS does not report is still reported, "
         "with the duration stated as unknown"],
    ),
    (
        "src/guardian.py",
        "the stopped-instance detector switched off, the IA-200 defect",
        "            if iid not in stopped:\n                continue",
        "            if True:\n                continue",
        ["a volume attached to an instance stopped for weeks is reported as waste",
         "all four of the account's idle volumes are reported, one item each",
         "the waste total for that account is 2.56 a month",
         "the account of 29 September 2026 does not report as clean"],
    ),
    (
        "src/guardian.py",
        "everything treated as managed, the IA-199 detector blinded",
        '    return any(t.get("Key") == MANAGED_BY_TAG and t.get("Value") == MANAGED_BY_VALUE',
        "    return True or any(t.get(\"Key\") == MANAGED_BY_TAG and t.get(\"Value\") == MANAGED_BY_VALUE",
        ["a resource with no ManagedBy tag is reported as undeclared",
         "the undeclared volume is reported, not only the undeclared instance"],
    ),
    (
        "src/guardian.py",
        "the undeclared check narrowed to instances, dropping volumes",
        '    for v in ec2.describe_volumes()["Volumes"]:\n        if _is_managed(v):\n            continue',
        '    for v in []:\n        if _is_managed(v):\n            continue',
        ["the undeclared volume is reported, not only the undeclared instance"],
    ),
    (
        "src/guardian.py",
        "a detector announced that does not exist",
        '    ("unused_ips",',
        '    ("unused_ips_typo",',
        ["every detector named in DETECTORS exists as a function"],
    ),
    (
        "src/dashboard.py",
        "an unreadable figure painted as zero, the guard that had no invariant",
        "    if x is None:",
        "    if False:",
        ["a figure that could not be read renders as unknown, and not as zero"],
    ),
    (
        "fakes.py",
        "the fake stops refusing filters it does not model",
        "                raise UnsupportedFilter(\n                    f\"describe_instances does not implement the filter {key!r}. \"",
        "                pass\n                _unused = (\n                    f\"describe_instances does not implement the filter {key!r}. \"",
        ["control: the fake EC2 refuses a filter it does not model instead of returning everything"],
    ),
]


def run_suite(cwd: Path) -> tuple[int, str]:
    proc = subprocess.run([sys.executable, "test_invariants.py"],
                          cwd=cwd, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr


def main() -> int:
    code, out = run_suite(HERE)
    if code != 0:
        print("The suite is already red on the working tree. Fix that first.")
        print(out)
        return 2
    print(f"baseline: {out.strip().splitlines()[-1]}  (exit {code})\n")

    problems: list[str] = []

    for target, name, find, replace, must_fail in MUTATIONS:
        with tempfile.TemporaryDirectory() as tmp:
            lab = Path(tmp) / "lab"
            shutil.copytree(HERE, lab, ignore=shutil.ignore_patterns(
                "__pycache__", ".git", ".github", "infra"))

            source = (lab / target).read_text(encoding="utf-8")
            if find not in source:
                problems.append(f"{name}: the text to mutate is no longer in {target}")
                print(f"SKIP  {name}\n        the anchor has moved, so this proves nothing\n")
                continue
            (lab / target).write_text(source.replace(find, replace, 1), encoding="utf-8")

            code, out = run_suite(lab)
            reddened = [line[5:] for line in out.splitlines() if line.startswith("FAIL ")]

            print(f"mutation: {name}")
            print(f"  in                   {target}")
            print(f"  suite exit code      {code}   (must be non-zero)")
            print(f"  invariants gone red  {len(reddened)}")

            if code == 0:
                problems.append(f"{name}: the suite stayed green")
                print("  RESULT  the suite did not notice. The rule is unproven.")
            else:
                missing = [inv for inv in must_fail if inv not in reddened]
                if missing:
                    problems.append(f"{name}: expected red but green: {missing}")
                    print(f"  RESULT  wrong invariants caught it, missing: {missing}")
                else:
                    for inv in must_fail:
                        print(f"          - {inv}")
                    print("  RESULT  caught, by the invariants that should catch it")
            print()

    if problems:
        print(f"{len(problems)} mutation(s) not caught:")
        for p in problems:
            print(f"  - {p}")
        return 1

    print(f"all {len(MUTATIONS)} mutations were caught. The suite can fail.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
