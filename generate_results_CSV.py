##############################################################
#            Projeto de Formatura I - SCC0670                #
#                                                            #
#      By: Artur Brenner Weber                               #
#      email: arturweber@usp.br                              #
#      Last Update: 26/5/2026                                #
#                                                            #
#  Generate a CSV index of the results                       #
##############################################################

#!/usr/bin/env python3
import re
import csv
from pathlib import Path

DATA_WIDTH = 8
KERNEL_X = 3
KERNEL_Y = 3

RESULTS_DIR = Path("results")

PAT = re.compile(
    r"^simd(?P<simd>\d+)_pe(?P<pe>\d+)_maxchannels(?P<maxch>\d+)_tgtclkfreq(?P<freq>[\deE\+\-\.]+)$"
)

def ceil_div(a, b):
    return (a + b - 1) // b

def compute_max_input_dim_bits(max_channels: int, simd: int) -> int:
    max_dot_lanes = max_channels * KERNEL_X * KERNEL_Y
    max_folds = ceil_div(max_dot_lanes, simd)
    pad_lanes = max_folds * simd
    return pad_lanes * DATA_WIDTH

def main():
    if not RESULTS_DIR.exists():
        raise SystemExit(f"ERROR: '{RESULTS_DIR}' not found (run from repo root?)")

    rows = []
    for p in sorted(RESULTS_DIR.iterdir()):
        if not p.is_dir():
            continue
        m = PAT.match(p.name)
        if not m:
            continue

        simd = int(m.group("simd"))
        pe = int(m.group("pe"))
        maxch = int(m.group("maxch"))
        freq = float(m.group("freq"))

        max_input_dim_bits = compute_max_input_dim_bits(maxch, simd)
        max_input_dim_bytes = max_input_dim_bits // 8

        rows.append({
            "SIMD": simd,
            "PE": pe,
            "MAX_CHANNELS": maxch,
            "MAX_INPUT_DIM_bits": max_input_dim_bits,
            "MAX_INPUT_DIM_bytes": max_input_dim_bytes,
            "target_freq_hz": int(freq) if freq.is_integer() else freq,
            "folder": p.name,
        })

    if not rows:
        raise SystemExit("No matching result folders found.")

    header = ["SIMD", "PE", "MAX_CHANNELS", "MAX_INPUT_DIM_bits", "MAX_INPUT_DIM_bytes", "target_freq_hz", "folder"]
    colw = {h: max(len(h), max(len(str(r[h])) for r in rows)) for h in header}
    print(" | ".join(h.ljust(colw[h]) for h in header))
    print("-+-".join("-" * colw[h] for h in header))
    for r in rows:
        print(" | ".join(str(r[h]).ljust(colw[h]) for h in header))

    # Write CSV inside results/ to avoid permission issues in repo root
    out_csv = RESULTS_DIR / "results_index.csv"
    try:
        with out_csv.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=header)
            w.writeheader()
            w.writerows(rows)
        print(f"\nWrote {out_csv} ({len(rows)} rows).")
    except OSError as e:
        print(f"\nWARNING: Could not write CSV to {out_csv}: {e}")
        print("If you want CSV output, run from a writable directory or change out_csv path.")

if __name__ == "__main__":
    main()