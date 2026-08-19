# FinOps Copilot (Agentic AI)

A READ-ONLY agentic layer over the AWS FinOps Guardian. An LLM agent reads cost/waste
data through tools, reasons about it, and produces a prioritized, guardrailed action
plan + executive brief - validated by an evaluation harness.

## Guardrails
- Read-only tools: the agent can see everything and change nothing.
- No invented numbers: only figures returned by tools.
- Propose, never execute: actions go to a human for approval.
- Deterministic invariant: top_action is derived in code from the ranked list.

## Files
- copilot.py - read-only tools, guardrail prompt, tool-use loop, structured plan().
- evals.py - eval harness (total / top / hallucination / policy) + free self-test.
- report.json - sample Guardian output.  fixtures/ - golden test cases.

## Run
    pip install anthropic
    set ANTHROPIC_API_KEY=...     # your key (never commit it)
    python copilot.py            # agent reads data -> action_plan.json + exec_brief.md
    python evals.py --selftest    # validate the checks (no API cost)
    python evals.py               # score the agent vs golden cases (go/no-go gate)

Built hands-on, free-tier friendly, honest about limits.