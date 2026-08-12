# iOS Simulator Density on EC2 Mac

**How many iOS simulators can one Mac run at once?** This repo answers that
empirically. It boots simulators in increasing waves (N = 1, 2, 4, 8, …),
launches a trivial app in each, verifies each one actually rendered, samples
host resources, and records where things break. The output is a number with a
graph behind it: the **reliable working point** and the **hard ceiling**.

The eventual target is an [AWS EC2 Mac](aws/README.md) dedicated host driven by
CI — but everything here runs on any Mac with Xcode, so the whole harness is
proven for free before a paid host is ever allocated.

> Full plan and rationale: **[roadmap](https://claude.ai/code/artifact/0b6a9ca5-7e9c-4e41-8b3f-ffa19ad5ad4d)** (phases 0–6).

---

## Phase 0 — run it locally (no AWS)

Requires: a Mac, Xcode + command line tools, an installed iOS simulator runtime.
[Homebrew](https://brew.sh) is used to fetch `xcodegen` if it isn't present.

```bash
make bootstrap    # install xcodegen, generate the project, build the app once
make smoke        # fastest end-to-end check: N=1 and N=2, one trial each
make sweep        # the real sweep (default N = 1 2 4 8, 3 repeats)
make analyze      # summarize the latest run into the two headline numbers
```

Push further once the small runs are green:

```bash
./harness/sweep.sh --app app/build/Build/Products/Debug-iphonesimulator/SimDensity.app \
  --levels "1 2 4 8 16 24 32" --repeats 3
```

## What's here

| Path | What it is |
|------|------------|
| `app/` | Trivial SwiftUI app (one full-bleed screen) + XcodeGen `project.yml`. Kept trivial on purpose — we measure the platform, not the app. |
| `scripts/bootstrap.sh` | One-time prep: installs tooling, generates the Xcode project, builds the `.app` once. |
| `harness/sweep.sh` | The experiment. Creates/boots/installs/launches/verifies N sims per trial and writes one CSV row per trial. |
| `harness/analyze.py` | Turns `results.csv` into the reliable-working-point and hard-ceiling numbers (+ charts if matplotlib is present). |
| `aws/` | Provisioning runbook for the EC2 Mac dedicated host (Phase 1). |

## How the measurement works

Each trial at level **N**:

1. **create** N fresh simulators of one fixed device type + runtime,
2. **boot** them together and wait for each to reach `Booted` (with a deadline),
3. **install** the prebuilt app and **launch** it in every booted sim,
4. **verify render** — a booted-but-blank sim produces a tiny screenshot, so a
   screenshot below a byte threshold counts as *not actually rendered*
   (guards against "booted ≠ working" under load),
5. **sample** host memory, load average, process count, and swap,
6. **tear down** — shut down and delete every sim it created.

Two numbers fall out (see `analyze.py`):

- **Reliable working point** — largest N where *every* trial booted, launched,
  and rendered all N sims with no failure mode.
- **Hard ceiling** — smallest N where any sim failed to boot.

### Why "how many" is a real question

There's no fixed CoreSimulator limit — density is bound by **RAM first**, then
the per-user process (~2,500 by default) and open-file limits. So the ceiling is
hardware-dependent and worth measuring, and it's expected to scale with a box's
memory. That's exactly what the sweep quantifies.

## Notes / knobs

- `--stop-on-fail` halts the sweep at the first level that isn't 100% clean.
- `--device` / `--runtime` hold the rest of the experiment fixed; vary only N.
- The harness never leaves simulators behind — it deletes what it creates, even
  on Ctrl-C, so repeated runs start clean.
