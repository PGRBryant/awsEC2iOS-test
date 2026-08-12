#!/usr/bin/env python3
"""Summarize a sweep results.csv into the two numbers that matter.

- Hard ceiling:           smallest N where any simulator failed to boot.
- Reliable working point: largest N where EVERY trial booted, launched, and
                          rendered all N sims with no failure mode.

Stdlib only, so it runs anywhere. If matplotlib happens to be installed it also
drops pass-rate and boot-time charts next to the CSV; otherwise it skips them.

Usage: python3 analyze.py path/to/results.csv
"""
import csv
import statistics
import sys
from collections import defaultdict


def load(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def main():
    if len(sys.argv) != 2:
        print("usage: analyze.py <results.csv>", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
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

    _maybe_charts(path, levels, by_level)


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
