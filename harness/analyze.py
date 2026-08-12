#!/usr/bin/env python3
"""Summarize a sweep results.csv into the two numbers that matter.

- Hard ceiling:           smallest N where any simulator failed to boot.
- Reliable working point: largest N where EVERY trial booted, launched, and
                          rendered all N sims with no failure mode.

Stdlib only, so it runs anywhere. If matplotlib happens to be installed it also
drops pass-rate and boot-time charts next to the CSV; otherwise it skips them.

Usage: python3 analyze.py path/to/results.csv [--report out.md]
"""
import csv
import statistics
import sys
from collections import defaultdict

# RAM per EC2 Mac instance type (GiB) — for extrapolating measured density.
EC2_TYPES = [
    ("mac2.metal (M1)", 16),
    ("mac-m4.metal (M4)", 24),
    ("mac2-m2.metal (M2)", 24),
    ("mac2-m2pro.metal (M2 Pro)", 32),
    ("mac-m4pro.metal (M4 Pro)", 48),
]
USABLE_RAM_FRACTION = 0.85  # leave headroom for macOS + tooling


def load(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def ram_model(rows):
    """Least-squares fit of host memory vs actually-booted sims.

    Returns (slope_mb_per_sim, intercept_mb) or None when the data can't
    support a fit (fewer than 3 distinct boot counts, or a degenerate slope).
    """
    pts = [(int(r["boots_ok"]), int(r["mem_used_mb"]))
           for r in rows
           if r["boots_ok"].isdigit() and r["mem_used_mb"].isdigit()
           and int(r["mem_used_mb"]) > 0]
    xs = sorted({x for x, _ in pts})
    if len(xs) < 3:
        return None
    n = len(pts)
    sx = sum(x for x, _ in pts)
    sy = sum(y for _, y in pts)
    sxx = sum(x * x for x, _ in pts)
    sxy = sum(x * y for x, y in pts)
    denom = n * sxx - sx * sx
    if denom == 0:
        return None
    slope = (n * sxy - sx * sy) / denom
    intercept = (sy - slope * sx) / n
    if slope < 50:  # < 50MB/sim means memory isn't what we measured
        return None
    return slope, intercept


def predict(slope, intercept):
    """Predicted max sims per EC2 instance type from the fitted RAM model."""
    out = []
    for name, gb in EC2_TYPES:
        usable = gb * 1024 * USABLE_RAM_FRACTION
        out.append((name, gb, max(0, int((usable - intercept) / slope))))
    return out


def main():
    argv = sys.argv[1:]
    report_path = None
    if "--report" in argv:
        i = argv.index("--report")
        try:
            report_path = argv[i + 1]
        except IndexError:
            print("--report needs a path", file=sys.stderr)
            sys.exit(2)
        del argv[i:i + 2]
    if len(argv) != 1:
        print("usage: analyze.py <results.csv> [--report out.md]", file=sys.stderr)
        sys.exit(2)
    path = argv[0]
    rows = load(path)
    if not rows:
        print("no data rows in", path, file=sys.stderr)
        sys.exit(1)

    by_level = defaultdict(list)
    for r in rows:
        by_level[int(r["level"])].append(r)

    levels = sorted(by_level)
    reliable = None       # largest fully-clean N
    hard_ceiling = None   # smallest N with a boot failure

    print(f"\n  Sweep summary  ({path})")
    print(f"  device={rows[0]['device']}  runtime={rows[0]['runtime'].split('.')[-1]}")
    print("  " + "-" * 74)
    print(f"  {'N':>4} {'trials':>7} {'boot%':>7} {'render%':>8} "
          f"{'boot_wall_s':>12} {'peak_mem_gb':>12} {'fail modes':>12}")
    print("  " + "-" * 74)

    for n in levels:
        trs = by_level[n]
        t = len(trs)
        boot_rate = sum(int(r["boots_ok"]) for r in trs) / (n * t) * 100
        render_rate = sum(int(r["renders_ok"]) for r in trs) / (n * t) * 100
        walls = [int(r["boot_wall_ms"]) for r in trs if r["boot_wall_ms"].isdigit()]
        wall_s = statistics.mean(walls) / 1000 if walls else 0
        peak_mem = max((int(r["mem_used_mb"]) for r in trs if r["mem_used_mb"].isdigit()), default=0) / 1024
        modes = sorted({r["failure_mode"] for r in trs if r["failure_mode"]})
        fully_clean = all(int(r["renders_ok"]) == n and not r["failure_mode"] for r in trs)
        any_boot_fail = any(int(r["boots_ok"]) < n for r in trs)

        if fully_clean:
            reliable = n
        if hard_ceiling is None and any_boot_fail:
            hard_ceiling = n

        flag = " " if fully_clean else ("!" if any_boot_fail else "~")
        print(f" {flag}{n:>4} {t:>7} {boot_rate:>6.0f}% {render_rate:>7.0f}% "
              f"{wall_s:>12.1f} {peak_mem:>12.1f} {','.join(modes) or '-':>12}")

    print("  " + "-" * 74)
    print(f"\n  Reliable working point : {reliable if reliable is not None else 'none (even N=min degraded)'}")
    print(f"  Hard ceiling (boot)    : {hard_ceiling if hard_ceiling is not None else 'not reached in this sweep'}")
    print("  legend:  (blank)=clean  ~=degraded/render  !=boot failure\n")

    # --- RAM model + cross-hardware extrapolation ---
    fit = ram_model(rows)
    preds = None
    if fit:
        slope, intercept = fit
        preds = predict(slope, intercept)
        print(f"  RAM model: ~{slope:.0f} MB per booted sim over a "
              f"{intercept / 1024:.1f} GB base ({USABLE_RAM_FRACTION:.0%} usable RAM assumed)")
        print("  Predicted RAM-bound ceiling by EC2 Mac instance type:")
        for name, gb, n_pred in preds:
            print(f"    {name:<28} {gb:>3} GB  ->  ~{n_pred} sims")
        print("  (directional only — process/fd limits or CPU may bind first; "
              "verify on target)\n")
    else:
        print("  (not enough distinct boot counts for a RAM model — "
              "sweep more levels)\n")

    if report_path:
        _write_report(report_path, path, rows, levels, by_level,
                      reliable, hard_ceiling, fit, preds)
        print(f"  report written to {report_path}\n")

    _maybe_charts(path, levels, by_level)


def _write_report(out, csv_path, rows, levels, by_level,
                  reliable, hard_ceiling, fit, preds):
    """Markdown report — the Phase 5 deliverable, generated not hand-written."""
    L = []
    L.append("# Simulator density results\n")
    L.append(f"- **Reliable working point:** "
             f"{reliable if reliable is not None else 'none — even the smallest level degraded'}")
    L.append(f"- **Hard ceiling (first boot failure):** "
             f"{hard_ceiling if hard_ceiling is not None else 'not reached in this sweep'}")
    L.append(f"- Device: `{rows[0]['device']}` · Runtime: "
             f"`{rows[0]['runtime'].split('.')[-1]}` · Source: `{csv_path}`\n")
    L.append("| N | trials | boot % | render % | boot wall (s) | peak mem (GB) | failure modes |")
    L.append("|--:|--:|--:|--:|--:|--:|:--|")
    for n in levels:
        trs = by_level[n]
        t = len(trs)
        boot = sum(int(r["boots_ok"]) for r in trs) / (n * t) * 100
        rend = sum(int(r["renders_ok"]) for r in trs) / (n * t) * 100
        walls = [int(r["boot_wall_ms"]) for r in trs if r["boot_wall_ms"].isdigit()]
        wall = statistics.mean(walls) / 1000 if walls else 0
        peak = max((int(r["mem_used_mb"]) for r in trs
                    if r["mem_used_mb"].isdigit()), default=0) / 1024
        modes = ", ".join(sorted({r["failure_mode"] for r in trs if r["failure_mode"]})) or "—"
        L.append(f"| {n} | {t} | {boot:.0f}% | {rend:.0f}% | {wall:.1f} | {peak:.1f} | {modes} |")
    if fit and preds:
        slope, intercept = fit
        L.append(f"\n## RAM model\n")
        L.append(f"~**{slope:.0f} MB per booted simulator** over a "
                 f"{intercept / 1024:.1f} GB base "
                 f"({USABLE_RAM_FRACTION:.0%} of RAM assumed usable).\n")
        L.append("| EC2 instance | RAM | predicted ceiling |")
        L.append("|:--|--:|--:|")
        for name, gb, n_pred in preds:
            L.append(f"| `{name}` | {gb} GB | ~{n_pred} sims |")
        L.append("\n*Directional only: process/fd limits or CPU can bind before "
                 "RAM does — verify on the target instance.*")
    with open(out, "w") as f:
        f.write("\n".join(L) + "\n")


def _maybe_charts(path, levels, by_level):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except Exception:
        print("  (matplotlib not installed — skipping charts; table above is the result)\n")
        return

    render = [sum(int(r["renders_ok"]) for r in by_level[n]) /
              (n * len(by_level[n])) * 100 for n in levels]
    walls = []
    for n in levels:
        w = [int(r["boot_wall_ms"]) for r in by_level[n] if r["boot_wall_ms"].isdigit()]
        walls.append(statistics.mean(w) / 1000 if w else 0)

    fig, (a1, a2) = plt.subplots(1, 2, figsize=(11, 4))
    a1.plot(levels, render, "o-", color="#0d8f86")
    a1.set(title="Render success vs N", xlabel="concurrent sims (N)", ylabel="render %", ylim=(0, 105))
    a1.grid(alpha=.3)
    a2.plot(levels, walls, "o-", color="#d9622b")
    a2.set(title="Boot wall-time vs N", xlabel="concurrent sims (N)", ylabel="seconds")
    a2.grid(alpha=.3)
    fig.tight_layout()
    out = path.rsplit(".", 1)[0] + "-charts.png"
    fig.savefig(out, dpi=130)
    print(f"  charts written to {out}\n")


if __name__ == "__main__":
    main()
