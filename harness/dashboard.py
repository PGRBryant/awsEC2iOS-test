#!/usr/bin/env python3
"""Generate a self-contained HTML dashboard from sweep/shard results.

Reads a results directory (results.csv, plus timeline.csv and speedup.csv when
present) and writes one dependency-free HTML file with inline-SVG charts:
stat tiles, render-success and boot-time curves, the RAM model fit, resource
timelines, the shard speedup curve, and the raw results table.

Usage:
    python3 dashboard.py <results-dir> [--shard <speedup.csv>] [--out <file.html>]

Palette (#0d8f86 teal / #d9622b heat) is CVD-validated for light AND dark
surfaces — marks keep the same hexes in both themes; only surfaces/ink swap.
"""
import csv
import os
import statistics
import sys
from collections import defaultdict

from analyze import USABLE_RAM_FRACTION, headline, load, predict, ram_model

TEAL = "#0d8f86"
HEAT = "#d9622b"

W, H = 560, 230
PAD_L, PAD_R, PAD_T, PAD_B = 46, 14, 14, 30
PW, PH = W - PAD_L - PAD_R, H - PAD_T - PAD_B


def nice_ticks(lo, hi, n=4):
    if hi <= lo:
        hi = lo + 1
    raw = (hi - lo) / n
    mag = 10 ** len(str(int(raw))) / 10 if raw >= 1 else 1
    for step in (1, 2, 2.5, 5, 10):
        if raw <= step * mag:
            step *= mag
            break
    else:
        step = 10 * mag
    t, ticks = (int(lo / step)) * step, []
    while t <= hi + step * 0.001:
        if t >= lo - step * 0.001:
            ticks.append(round(t, 6))
        t += step
    return ticks or [lo, hi]


def scales(xs, ys, y0=0.0):
    xlo, xhi = min(xs), max(xs)
    if xhi == xlo:
        xhi = xlo + 1
    ylo, yhi = min(y0, min(ys)), max(ys) * 1.08 or 1
    sx = lambda v: PAD_L + (v - xlo) / (xhi - xlo) * PW
    sy = lambda v: PAD_T + PH - (v - ylo) / (yhi - ylo) * PH
    return sx, sy, (xlo, xhi, ylo, yhi)


def grid_and_axes(sx, sy, dom, xticks=None, y_fmt=lambda v: f"{v:g}"):
    xlo, xhi, ylo, yhi = dom
    out = []
    for t in nice_ticks(ylo, yhi):
        y = sy(t)
        out.append(f'<line class="grid" x1="{PAD_L}" y1="{y:.1f}" x2="{W-PAD_R}" y2="{y:.1f}"/>')
        out.append(f'<text class="tick" x="{PAD_L-6}" y="{y+3.5:.1f}" text-anchor="end">{y_fmt(t)}</text>')
    for t in (xticks if xticks is not None else nice_ticks(xlo, xhi)):
        out.append(f'<text class="tick" x="{sx(t):.1f}" y="{H-10}" text-anchor="middle">{t:g}</text>')
    out.append(f'<line class="axis" x1="{PAD_L}" y1="{PAD_T+PH}" x2="{W-PAD_R}" y2="{PAD_T+PH}"/>')
    return "".join(out)


def hits(pts, tips):
    """Oversized transparent hover targets carrying tooltip text."""
    return "".join(
        f'<circle class="hit" cx="{x:.1f}" cy="{y:.1f}" r="14" data-tip="{t}"/>'
        for (x, y), t in zip(pts, tips))


def line_chart(title, xs, ys, tips, color, y_fmt=lambda v: f"{v:g}", note=""):
    sx, sy, dom = scales(xs, ys)
    pts = [(sx(x), sy(y)) for x, y in zip(xs, ys)]
    path = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts)
    dots = "".join(f'<circle class="dot" cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{color}"/>'
                   for x, y in pts)
    end_lab = (f'<text class="dlabel" x="{min(pts[-1][0], W - 26):.1f}" y="{pts[-1][1]-10:.1f}" '
               f'text-anchor="middle">{y_fmt(round(ys[-1], 1))}</text>') if pts else ""
    return f'''<figure><figcaption>{title}{f' <span class="note">{note}</span>' if note else ''}</figcaption>
<svg viewBox="0 0 {W} {H}" role="img" aria-label="{title}">
{grid_and_axes(sx, sy, dom, xticks=xs, y_fmt=y_fmt)}
<path d="{path}" fill="none" stroke="{color}" stroke-width="2"/>{dots}{end_lab}{hits(pts, tips)}
</svg></figure>'''


def area_chart(title, xs, ys, tips, color, y_fmt=lambda v: f"{v:g}"):
    sx, sy, dom = scales(xs, ys)
    pts = [(sx(x), sy(y)) for x, y in zip(xs, ys)]
    top = " L".join(f"{x:.1f} {y:.1f}" for x, y in pts)
    base = PAD_T + PH
    area = f"M{pts[0][0]:.1f} {base} L{top} L{pts[-1][0]:.1f} {base} Z"
    line = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in pts)
    step = max(1, len(pts) // 60)
    return f'''<figure><figcaption>{title}</figcaption>
<svg viewBox="0 0 {W} {H}" role="img" aria-label="{title}">
{grid_and_axes(sx, sy, dom, y_fmt=y_fmt)}
<path d="{area}" fill="{color}" opacity="0.16"/>
<path d="{line}" fill="none" stroke="{color}" stroke-width="2"/>
{hits(pts[::step], tips[::step])}
</svg></figure>'''


def speedup_chart(rows):
    ns = [int(r["shards"]) for r in rows]
    base = next((int(r["wall_ms"]) for r in rows if int(r["shards"]) == 1), None)
    if not base:
        return ""
    meas = [base / int(r["wall_ms"]) if int(r["wall_ms"]) else 0 for r in rows]
    sx, sy, dom = scales(ns, ns, y0=0)   # ideal line spans to max N
    mpts = [(sx(n), sy(v)) for n, v in zip(ns, meas)]
    ipts = [(sx(n), sy(n)) for n in ns]
    mpath = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in mpts)
    ipath = "M" + " L".join(f"{x:.1f} {y:.1f}" for x, y in ipts)
    dots = "".join(f'<circle class="dot" cx="{x:.1f}" cy="{y:.1f}" r="4" fill="{TEAL}"/>' for x, y in mpts)
    tips = [f"{n} shards: {v:.2f}x (ideal {n}x)" for n, v in zip(ns, meas)]
    return f'''<figure><figcaption>Suite speedup vs shard count
 <span class="legend"><i style="background:{TEAL}"></i>measured <i class="dash"></i>ideal</span></figcaption>
<svg viewBox="0 0 {W} {H}" role="img" aria-label="Suite speedup vs shard count">
{grid_and_axes(sx, sy, dom, xticks=ns, y_fmt=lambda v: f"{v:g}x")}
<path d="{ipath}" fill="none" stroke="var(--muted)" stroke-width="1.5" stroke-dasharray="5 5"/>
<path d="{mpath}" fill="none" stroke="{TEAL}" stroke-width="2"/>{dots}
<text class="dlabel" x="{min(mpts[-1][0], W - 26):.1f}" y="{mpts[-1][1]-10:.1f}" text-anchor="middle">{meas[-1]:.2f}x</text>
{hits(mpts, tips)}
</svg></figure>'''


def stat(label, value, note=""):
    return (f'<div class="tile"><div class="v">{value}</div><div class="l">{label}</div>'
            f'{f"<div class=n>{note}</div>" if note else ""}</div>')


def build(results_dir, shard_csv, out_path):
    rows = load(os.path.join(results_dir, "results.csv"))
    if not rows:
        print("no results.csv rows in", results_dir, file=sys.stderr)
        sys.exit(1)
    by_level = defaultdict(list)
    for r in rows:
        by_level[int(r["level"])].append(r)
    levels = sorted(by_level)
    reliable, ceiling = headline(rows)
    fit = ram_model(rows)
    profile = rows[0].get("profile", "IDLE") or "IDLE"
    device = rows[0]["device"].split(".")[-1]
    runtime = rows[0]["runtime"].split(".")[-1]

    render_pct, boot_s, tips_r, tips_b = [], [], [], []
    for n in levels:
        trs = by_level[n]
        pct = sum(int(r["renders_ok"]) for r in trs) / (n * len(trs)) * 100
        walls = [int(r["boot_wall_ms"]) for r in trs if r["boot_wall_ms"].isdigit()]
        ws = statistics.mean(walls) / 1000 if walls else 0
        modes = sorted({r["failure_mode"] for r in trs if r["failure_mode"]})
        render_pct.append(pct)
        boot_s.append(ws)
        tips_r.append(f"N={n}: {pct:.0f}% rendered" + (f" — {', '.join(modes)}" if modes else ""))
        tips_b.append(f"N={n}: boot wall {ws:.1f}s")

    charts = [
        line_chart("Render success vs N", levels, render_pct, tips_r, TEAL,
                   y_fmt=lambda v: f"{v:g}%"),
        line_chart("Boot wall-time vs N", levels, boot_s, tips_b, HEAT,
                   y_fmt=lambda v: f"{v:g}s"),
    ]

    # edge-AI throughput (INFER profile): does aggregate inference scale with N?
    infer_vals = [statistics.mean(float(r.get("infer_ops", 0) or 0)
                                  for r in by_level[n]) for n in levels]
    has_infer = any(v > 0 for v in infer_vals)
    if has_infer:
        charts.append(line_chart(
            "Aggregate edge inference vs N", levels, infer_vals,
            [f"N={n}: {v:.1f} inf/s total ({v/n:.1f}/sim)"
             for n, v in zip(levels, infer_vals)],
            TEAL, y_fmt=lambda v: f"{v:g}/s",
            note="on-device Vision OCR, all sims summed"))

    if fit:
        slope, intercept = fit
        xs = [int(r["boots_ok"]) for r in rows if int(r.get("mem_used_mb", "0") or 0) > 0]
        ys = [int(r["mem_used_mb"]) / 1024 for r in rows if int(r.get("mem_used_mb", "0") or 0) > 0]
        tips = [f"{x} booted: {y:.1f} GB" for x, y in zip(xs, ys)]
        charts.append(line_chart(
            "Host memory vs booted sims", xs, ys, tips, TEAL,
            y_fmt=lambda v: f"{v:g}G", note=f"fit ~{slope:.0f} MB/sim"))

    tl_path = os.path.join(results_dir, "timeline.csv")
    if os.path.exists(tl_path):
        tl = load(tl_path)
        if len(tl) >= 3:
            t0 = int(tl[0]["ts_ms"])
            ts = [(int(r["ts_ms"]) - t0) / 1000 for r in tl]
            mem = [int(r["mem_used_mb"]) / 1024 for r in tl]
            boo = [int(r["booted"]) for r in tl]
            charts.append(area_chart("Memory timeline (whole sweep)", ts, mem,
                                     [f"t+{t:.0f}s: {m:.1f} GB" for t, m in zip(ts, mem)],
                                     TEAL, y_fmt=lambda v: f"{v:g}G"))
            charts.append(area_chart("Booted simulators timeline", ts, boo,
                                     [f"t+{t:.0f}s: {b} booted" for t, b in zip(ts, boo)],
                                     HEAT))

    shard_rows = []
    if shard_csv and os.path.exists(shard_csv):
        shard_rows = load(shard_csv)
        if shard_rows:
            charts.append(speedup_chart(shard_rows))

    tiles = [
        stat("reliable working point", reliable if reliable is not None else "—",
             "largest fully-clean N"),
        stat("hard ceiling", ceiling if ceiling is not None else "not hit",
             "first boot failure"),
        stat("load profile", profile),
    ]
    if fit:
        slope, intercept = fit
        tiles.insert(2, stat("memory per sim", f"~{slope:.0f} MB",
                             f"{intercept/1024:.1f} GB base"))
    if has_infer:
        best_n = levels[infer_vals.index(max(infer_vals))]
        tiles.append(stat("edge AI throughput", f"{max(infer_vals):.1f} inf/s",
                          f"peak at N={best_n}"))
    if shard_rows:
        base = next((int(r["wall_ms"]) for r in shard_rows if int(r["shards"]) == 1), 0)
        best = min(shard_rows, key=lambda r: int(r["wall_ms"]))
        if base and int(best["wall_ms"]):
            tiles.append(stat("best suite speedup",
                              f"{base/int(best['wall_ms']):.2f}x",
                              f"at {best['shards']} shards"))

    pred_rows = ""
    if fit:
        for name, gb, n_pred in predict(*fit):
            pred_rows += (f"<tr><td>{name}</td><td class='num'>{gb} GB</td>"
                          f"<td class='num'>~{n_pred}</td></tr>")

    table = ["<tr><th>N</th><th>trial</th><th>boot</th><th>render</th>"
             "<th>wall s</th><th>mem GB</th><th>failure</th></tr>"]
    for r in rows:
        fm = r["failure_mode"]
        chip = f'<span class="chip">{fm}</span>' if fm else "—"
        table.append(
            f"<tr><td class='num'>{r['level']}</td><td class='num'>{r['repeat']}</td>"
            f"<td class='num'>{r['boots_ok']}/{r['level']}</td>"
            f"<td class='num'>{r['renders_ok']}/{r['level']}</td>"
            f"<td class='num'>{int(r['boot_wall_ms'])/1000:.1f}</td>"
            f"<td class='num'>{int(r['mem_used_mb'])/1024:.1f}</td><td>{chip}</td></tr>")

    html = TEMPLATE.format(
        device=device, runtime=runtime, profile=profile,
        tiles="".join(tiles), charts="\n".join(charts),
        pred=(f'<figure class="tablefig"><figcaption>Predicted RAM-bound ceiling by EC2 instance '
              f'({USABLE_RAM_FRACTION:.0%} usable)</figcaption><div class="scroll"><table>'
              f'<tr><th>instance</th><th>RAM</th><th>predicted N</th></tr>{pred_rows}'
              f'</table></div></figure>') if pred_rows else "",
        table=f'<div class="scroll"><table>{"".join(table)}</table></div>')
    with open(out_path, "w") as f:
        f.write(html)
    print("dashboard written to", out_path)


TEMPLATE = '''<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SimDensity Dashboard</title>
<style>
:root {{
  --ground:#f4f6f8; --surface:#ffffff; --ink:#171b21; --ink-soft:#3c434e;
  --muted:#667080; --line:#d9dee4; --grid:#e7ebef;
  --mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace;
  --sans:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif;
}}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{
  --ground:#0f1216; --surface:#171b21; --ink:#eaeef3; --ink-soft:#c2cad3;
  --muted:#8a94a2; --line:#2a313a; --grid:#232a33;
}} }}
:root[data-theme="dark"] {{
  --ground:#0f1216; --surface:#171b21; --ink:#eaeef3; --ink-soft:#c2cad3;
  --muted:#8a94a2; --line:#2a313a; --grid:#232a33;
}}
*{{box-sizing:border-box}}
body{{margin:0;background:var(--ground);color:var(--ink);font-family:var(--sans);line-height:1.5}}
.wrap{{max-width:1180px;margin:0 auto;padding:28px 22px 80px}}
h1{{font-size:22px;letter-spacing:-.01em;margin:0}}
.sub{{font-family:var(--mono);font-size:12px;color:var(--muted);margin:4px 0 22px}}
.tiles{{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-bottom:22px}}
.tile{{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:14px 16px}}
.tile .v{{font-family:var(--mono);font-size:26px;font-weight:700;font-variant-numeric:tabular-nums}}
.tile .l{{font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted);margin-top:2px}}
.tile .n{{font-family:var(--mono);font-size:11px;color:var(--muted);margin-top:4px}}
.grid2{{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:14px}}
figure{{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:14px;margin:0}}
figcaption{{font-size:13px;font-weight:600;color:var(--ink-soft);margin-bottom:8px;display:flex;justify-content:space-between;align-items:baseline;gap:8px;flex-wrap:wrap}}
figcaption .note,.legend{{font-family:var(--mono);font-size:11px;color:var(--muted);font-weight:400}}
.legend i{{display:inline-block;width:14px;height:3px;border-radius:2px;vertical-align:middle;margin:0 4px 0 10px}}
.legend i.dash{{background:repeating-linear-gradient(90deg,var(--muted) 0 4px,transparent 4px 7px)}}
svg{{width:100%;height:auto;display:block}}
.grid{{stroke:var(--grid);stroke-width:1}}
.axis{{stroke:var(--line);stroke-width:1}}
.tick{{font:10.5px var(--mono);fill:var(--muted)}}
.dlabel{{font:11px var(--mono);fill:var(--ink-soft);font-weight:600}}
.dot{{stroke:var(--surface);stroke-width:2}}
.hit{{fill:transparent;cursor:crosshair}}
.scroll{{overflow-x:auto}}
table{{border-collapse:collapse;width:100%;font-size:13px;min-width:420px}}
th,td{{text-align:left;padding:6px 12px;border-bottom:1px solid var(--line)}}
th{{font-family:var(--mono);font-size:10.5px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}}
td.num{{font-family:var(--mono);font-variant-numeric:tabular-nums}}
.chip{{font-family:var(--mono);font-size:10.5px;background:#c53030;color:#fff;border-radius:99px;padding:1px 8px}}
.tablefig,.results{{margin-top:14px}}
#tip{{position:fixed;pointer-events:none;background:var(--ink);color:var(--ground);
  font:11.5px var(--mono);padding:5px 9px;border-radius:6px;opacity:0;transition:opacity .12s;z-index:9;white-space:nowrap}}
</style></head><body>
<div class="wrap">
<h1>SimDensity Dashboard</h1>
<p class="sub">{device} &middot; {runtime} &middot; profile {profile}</p>
<div class="tiles">{tiles}</div>
<div class="grid2">
{charts}
</div>
{pred}
<figure class="results"><figcaption>All trials</figcaption>{table}</figure>
</div>
<div id="tip"></div>
<script>
var tip=document.getElementById('tip');
document.addEventListener('mousemove',function(e){{
  var t=e.target.closest&&e.target.closest('.hit');
  if(t){{tip.textContent=t.dataset.tip;tip.style.opacity=1;
    tip.style.left=Math.min(e.clientX+14,innerWidth-tip.offsetWidth-8)+'px';
    tip.style.top=(e.clientY-30)+'px';}}
  else tip.style.opacity=0;
}});
</script>
</body></html>'''


def main():
    argv = sys.argv[1:]
    shard_csv, out_path = None, None
    if "--shard" in argv:
        i = argv.index("--shard"); shard_csv = argv[i + 1]; del argv[i:i + 2]
    if "--out" in argv:
        i = argv.index("--out"); out_path = argv[i + 1]; del argv[i:i + 2]
    if len(argv) != 1:
        print(__doc__, file=sys.stderr); sys.exit(2)
    results_dir = argv[0].rstrip("/")
    if shard_csv is None:
        cand = os.path.join(results_dir, "speedup.csv")
        shard_csv = cand if os.path.exists(cand) else None
    build(results_dir, shard_csv, out_path or os.path.join(results_dir, "dashboard.html"))


if __name__ == "__main__":
    main()
