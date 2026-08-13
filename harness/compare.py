#!/usr/bin/env python3
"""Compare sweep results across machines (laptop vs hosted runner vs EC2).

Usage:
    python3 compare.py laptop=results/a/results.csv ec2=results/b/results.csv
    python3 compare.py --report compare.md m1=...csv m2pro=...csv

Each argument is label=path/to/results.csv. Prints one row per machine:
RAM, reliable working point, hard ceiling, fitted MB-per-sim, and what the
fitted model predicts for that machine's own RAM (a sanity check: measured
and predicted ceilings should roughly agree when RAM is the binding limit).
"""
import sys

from analyze import USABLE_RAM_FRACTION, headline, load, ram_model


def one(label, path):
    rows = load(path)
    if not rows:
        return None
    reliable, ceiling = headline(rows)
    total_mb = max((int(r["mem_total_mb"]) for r in rows
                    if r["mem_total_mb"].isdigit()), default=0)
    fit = ram_model(rows)
    mb_per_sim = f"{fit[0]:.0f}" if fit else "—"
    if fit:
        slope, intercept = fit
        self_pred = f"~{max(0, int((total_mb * USABLE_RAM_FRACTION - intercept) / slope))}"
    else:
        self_pred = "—"
    return {
        "machine": label,
        "ram_gb": f"{total_mb / 1024:.0f}",
        "reliable": str(reliable) if reliable is not None else "—",
        "ceiling": str(ceiling) if ceiling is not None else "not hit",
        "mb_per_sim": mb_per_sim,
        "self_pred": self_pred,
    }


COLS = [("machine", "machine"), ("ram_gb", "RAM GB"), ("reliable", "reliable N"),
        ("ceiling", "hard ceiling"), ("mb_per_sim", "MB/sim"),
        ("self_pred", "predicted N")]


def main():
    argv = sys.argv[1:]
    report_path = None
    if "--report" in argv:
        i = argv.index("--report")
        report_path = argv[i + 1]
        del argv[i:i + 2]
    pairs = [a.split("=", 1) for a in argv if "=" in a]
    if not pairs:
        print(__doc__, file=sys.stderr)
        sys.exit(2)

    results = [r for r in (one(lbl, path) for lbl, path in pairs) if r]
    if not results:
        print("no usable data in any input", file=sys.stderr)
        sys.exit(1)

    widths = {k: max(len(h), *(len(r[k]) for r in results)) for k, h in COLS}
    header = "  ".join(h.rjust(widths[k]) for k, h in COLS)
    print("\n  " + header)
    print("  " + "-" * len(header))
    for r in results:
        print("  " + "  ".join(r[k].rjust(widths[k]) for k, _ in COLS))
    print("\n  predicted N = fitted RAM model applied to that machine's own RAM"
          f" ({USABLE_RAM_FRACTION:.0%} usable); agreement with the measured"
          " ceiling means RAM is the binding limit.\n")

    if report_path:
        lines = ["# Cross-machine comparison\n",
                 "| " + " | ".join(h for _, h in COLS) + " |",
                 "|" + "|".join("--:" for _ in COLS) + "|"]
        lines += ["| " + " | ".join(r[k] for k, _ in COLS) + " |" for r in results]
        lines.append("\n*predicted N: fitted RAM model applied to each machine's "
                     f"own RAM ({USABLE_RAM_FRACTION:.0%} usable).*")
        with open(report_path, "w") as f:
            f.write("\n".join(lines) + "\n")
        print(f"  report written to {report_path}\n")


if __name__ == "__main__":
    main()
