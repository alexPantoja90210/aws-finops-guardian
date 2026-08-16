#!/usr/bin/env python3
"""FinOps Guardian - Phase 4: render report.json into an HTML dashboard."""
import json

CSS = """
<style>
*{margin:0;padding:0;box-sizing:border-box;}
body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;
  background:#0a1324;color:#e6edf6;padding:40px;min-height:100vh;
  background-image:radial-gradient(800px 400px at 90% -5%, rgba(76,199,224,.10), transparent 60%);}
.wrap{max-width:1000px;margin:0 auto;}
.top{display:flex;align-items:center;gap:14px;border-bottom:1px solid rgba(255,255,255,.1);padding-bottom:20px;margin-bottom:28px;}
.dot{width:12px;height:12px;border-radius:50%;background:#4CC7E0;box-shadow:0 0 14px #4CC7E0;}
.top h1{font-size:26px;font-weight:800;letter-spacing:-.3px;}
.top .sub{margin-left:auto;font-size:13px;color:#8394ab;font-family:ui-monospace,monospace;}
.kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin-bottom:28px;}
.kpi{background:linear-gradient(180deg,#0e1a30,#0b1526);border:1px solid rgba(255,255,255,.08);border-radius:14px;padding:20px;}
.kpi .l{font-size:12px;color:#8394ab;text-transform:uppercase;letter-spacing:1px;font-weight:700;}
.kpi .v{font-size:32px;font-weight:800;margin-top:8px;}
.kpi .v.g{color:#37D399;} .kpi .v.a{color:#E7B24C;} .kpi .v.c{color:#4CC7E0;} .kpi .v.r{color:#F0736F;}
.card{background:linear-gradient(180deg,#0e1a30,#0b1526);border:1px solid rgba(255,255,255,.08);border-radius:14px;padding:24px;margin-bottom:22px;}
.card h2{font-size:14px;text-transform:uppercase;letter-spacing:1.5px;color:#4CC7E0;margin-bottom:14px;font-weight:800;}
.brief{font-size:17px;line-height:1.6;color:#d6e0ee;}
.actions{margin-top:16px;list-style:none;}
.actions li{padding:12px 0;border-top:1px solid rgba(255,255,255,.06);font-size:15px;display:flex;gap:12px;align-items:center;}
.actions li .n{color:#4CC7E0;font-weight:800;width:22px;}
.actions li .s{margin-left:auto;color:#E7B24C;font-weight:700;font-family:ui-monospace,monospace;white-space:nowrap;}
table{width:100%;border-collapse:collapse;font-size:14px;}
th{text-align:left;color:#8394ab;font-size:12px;text-transform:uppercase;letter-spacing:1px;padding:10px 12px;border-bottom:1px solid rgba(255,255,255,.1);}
td{padding:12px;border-bottom:1px solid rgba(255,255,255,.05);font-family:ui-monospace,monospace;}
.badge{padding:3px 9px;border-radius:6px;font-size:12px;font-weight:700;}
.badge.a{color:#E7B24C;background:rgba(231,178,76,.12);}
.foot{text-align:center;color:#5b6b82;font-size:12px;margin-top:24px;font-family:ui-monospace,monospace;}
.clean{color:#37D399;font-weight:700;font-size:16px;}
</style>
"""

def money(x): return f"${x:,.2f}"

def build_brief(r):
    fc = r["forecast"]; waste = r["waste"]; total = r["waste_monthly_usd"]; health = r["health_score"]
    p = [f"As of {r['generated_at'][:10]}, projected month-end spend is {money(fc['projected_eom'])} "
         f"against a {money(fc['budget'])} budget ({fc['status']})."]
    if waste:
        p.append(f"The account is carrying {len(waste)} unused or idle resource(s) costing an "
                 f"estimated {money(total)} per month.")
        top = sorted(waste, key=lambda w: w['est_monthly_usd'], reverse=True)[0]
        p.append(f"The biggest single item is {top['type'].replace('_',' ')} ({top['resource']}) "
                 f"at ~{money(top['est_monthly_usd'])}/mo — recommended action: {top['action'].lower()}.")
    else:
        p.append("No idle or orphaned resources were detected — the account is clean.")
    p.append(f"Overall governance health score: {health}/100.")
    return " ".join(p)

def main():
    with open("report.json") as f:
        r = json.load(f)
    fc = r["forecast"]; waste = r["waste"]; total = r["waste_monthly_usd"]; health = r["health_score"]
    budget_cls = "g" if fc["status"] == "OK" else "r"
    waste_cls = "g" if total == 0 else "a"
    health_cls = "g" if health >= 90 else ("a" if health >= 70 else "r")

    h = ["<!doctype html><html><head><meta charset='utf-8'>",
         "<meta name='viewport' content='width=device-width, initial-scale=1'>",
         "<title>FinOps Guardian</title>", CSS, "</head><body><div class='wrap'>"]
    h.append(f"<div class='top'><span class='dot'></span><h1>AWS FinOps Guardian</h1>"
             f"<span class='sub'>updated {r['generated_at'][:16].replace('T',' ')} UTC</span></div>")
    h.append("<div class='kpis'>")
    h.append(f"<div class='kpi'><div class='l'>Projected EOM</div><div class='v c'>{money(fc['projected_eom'])}</div></div>")
    h.append(f"<div class='kpi'><div class='l'>Budget</div><div class='v {budget_cls}'>{fc['status']}</div></div>")
    h.append(f"<div class='kpi'><div class='l'>Waste / mo</div><div class='v {waste_cls}'>{money(total)}</div></div>")
    h.append(f"<div class='kpi'><div class='l'>Health</div><div class='v {health_cls}'>{health}/100</div></div>")
    h.append("</div>")
    h.append("<div class='card'><h2>Executive Brief</h2>")
    h.append(f"<div class='brief'>{build_brief(r)}</div>")
    t3 = sorted(waste, key=lambda w: w['est_monthly_usd'], reverse=True)[:3]
    if t3:
        h.append("<ul class='actions'>")
        for i, w in enumerate(t3, 1):
            h.append(f"<li><span class='n'>{i}</span><span>{w['action']} — "
                     f"{w['type'].replace('_',' ')} <b>{w['resource']}</b></span>"
                     f"<span class='s'>save ~{money(w['est_monthly_usd'])}/mo</span></li>")
        h.append("</ul>")
    h.append("</div>")
    h.append("<div class='card'><h2>Findings — RAID Register</h2>")
    if waste:
        h.append("<table><tr><th>Type</th><th>Resource</th><th>Detail</th><th>Est. $/mo</th><th>Action</th></tr>")
        for w in waste:
            h.append(f"<tr><td><span class='badge a'>{w['type'].replace('_',' ')}</span></td>"
                     f"<td>{w['resource']}</td><td>{w['detail']}</td>"
                     f"<td>{money(w['est_monthly_usd'])}</td><td>{w['action']}</td></tr>")
        h.append("</table>")
    else:
        h.append("<div class='clean'>&#10003; No findings — all clear.</div>")
    h.append("</div>")
    h.append("<div class='foot'>Read-only &middot; authenticated by EC2 IAM role &middot; no keys on host</div>")
    h.append("</div></body></html>")
    with open("dashboard.html", "w") as f:
        f.write("".join(h))
    print("Wrote dashboard.html")

if __name__ == "__main__":
    main()
PYEOF
