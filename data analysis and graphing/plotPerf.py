#!/usr/bin/env python3
import csv
import matplotlib.pyplot as plt
import math
from pathlib import Path
from collections import defaultdict

# ---- Constants ----
CSV_PATH = Path("analysis/hardware_synthesis.csv")

# Set global font: Times New Roman, larger size
plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman"],
    "font.size": 18,
    "axes.labelsize": 20,
    "axes.titlesize": 20,
    "xtick.labelsize": 17,
    "ytick.labelsize": 17,
    "legend.fontsize": 16,
})

def plot_sweep(sweep_mode, fixed_vars, group_data, out_dir):
    group_data.sort(key=lambda item: item[0])

    x_vals = [d[0] for d in group_data]
    freqs_hz = [d[1] for d in group_data]
    freqs_mhz = [f / 1e6 for f in freqs_hz]
    gmacs_list = []

    # Calculate GMAC/s and set up labels/filename
    for x, freq in zip(x_vals, freqs_hz):
        if sweep_mode == "SIMD":
            pe_val, padlanes_val, simd_val = fixed_vars[0], fixed_vars[1], x
            xlabel = 'SIMD Size'
            label_str = f"PE = {pe_val}, PAD_LANES = {padlanes_val}"
            filename = f"sweep_SIMD_pe{pe_val}_padlanes{padlanes_val}.png"
        elif sweep_mode == "PE":
            simd_val, padlanes_val, pe_val = fixed_vars[0], fixed_vars[1], x
            xlabel = 'PE Size'
            label_str = f"SIMD = {simd_val}, PAD_LANES = {padlanes_val}"
            filename = f"sweep_PE_simd{simd_val}_padlanes{padlanes_val}.png"
        else: # PAD_LANES
            simd_val, pe_val, padlanes_val = fixed_vars[0], fixed_vars[1], x
            xlabel = 'PAD_LANES'
            label_str = f"SIMD = {simd_val}, PE = {pe_val}"
            filename = f"sweep_PADLANES_simd{simd_val}_pe{pe_val}.png"

        # Formula: GMAC/s = (PE * PAD_LANES * FMAX) / (1e9 * ((2 + PE * PAD_LANES) / SIMD))
        fold_qnt = math.ceil(padlanes_val / simd_val)
        total_cycles = 2 + (pe_val * fold_qnt)
        macs_total = pe_val * padlanes_val
        gmacs = (macs_total * freq) / (1e9 * total_cycles)
        gmacs_list.append(gmacs)

    # --- Plotting ---
    fig, ax1 = plt.subplots(figsize=(10, 6))

    color1 = 'tab:blue'
    ax1.set_xlabel(xlabel)
    ax1.set_ylabel('Max Frequency (MHz)', color=color1, fontweight='bold')
    line1, = ax1.plot(x_vals, freqs_mhz, color=color1, marker='o', linewidth=2, markersize=8, label="Fmax (MHz)")
    ax1.tick_params(axis='y', labelcolor=color1)
    if len(x_vals) > 1:
        ax1.set_xscale('log', base=2)
    else:
        ax1.set_xlim(x_vals[0] * 0.8, x_vals[0] * 1.2)
    ax1.set_xticks(x_vals)
    ax1.set_xticklabels([str(x) for x in x_vals])
    ax1.grid(True, which="both", ls="--", alpha=0.5)

    # --- Axis 2: GMAC/s ---
    ax2 = ax1.twinx()
    color2 = 'tab:red'
    ax2.set_ylabel('Max Performance (GMAC/s)', color=color2, fontweight='bold')
    line2, = ax2.plot(x_vals, gmacs_list, color=color2, marker='s', linewidth=2, markersize=8, label="GMAC/s")
    ax2.tick_params(axis='y', labelcolor=color2)

    lines = [line1, line2]
    labels = [l.get_label() for l in lines]
    ax1.legend(lines, labels, loc='center right')

    fig.tight_layout()

    filepath = out_dir / filename
    plt.savefig(filepath, dpi=300)
    plt.close(fig)
    print(f"Saved: {out_dir.name}/{filename} ({len(x_vals)} points)")

def main():
    if not CSV_PATH.exists():
        raise SystemExit(f"ERROR: Cannot find {CSV_PATH}.")

    dir_simd = Path("perfPlotperSIMD")
    dir_pe = Path("perfPlotperPE")
    dir_padlanes = Path("perfPlotperPAD_LANES")
    for d in [dir_simd, dir_pe, dir_padlanes]:
        d.mkdir(parents=True, exist_ok=True)

    unique_configs = {}
    with CSV_PATH.open("r", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row["PT_FMAX_HZ"]:
                simd = int(row["SIMD"])
                pe = int(row["PE"])
                padlanes = int(row["MAX_INP_DIM_bytes"])  # was MAX_INP_DIM, now PAD_LANES
                fmax = float(row["PT_FMAX_HZ"])
                key = (simd, pe, padlanes)
                if key not in unique_configs or fmax > unique_configs[key]:
                    unique_configs[key] = fmax

    print(f"Found {len(unique_configs)} unique valid hardware configurations in CSV.\n")

    sweep_simd_groups = defaultdict(list)
    sweep_pe_groups = defaultdict(list)
    sweep_padlanes_groups = defaultdict(list)

    for (simd, pe, padlanes), fmax in unique_configs.items():
        sweep_simd_groups[(pe, padlanes)].append((simd, fmax))
        sweep_pe_groups[(simd, padlanes)].append((pe, fmax))
        sweep_padlanes_groups[(simd, pe)].append((padlanes, fmax))

    print("--- Generating SIMD Sweeps ---")
    for (pe, padlanes), data in sweep_simd_groups.items():
        plot_sweep("SIMD", (pe, padlanes), data, dir_simd)

    print("\n--- Generating PE Sweeps ---")
    for (simd, padlanes), data in sweep_pe_groups.items():
        plot_sweep("PE", (simd, padlanes), data, dir_pe)

    print("\n--- Generating PAD_LANES Sweeps ---")
    for (simd, pe), data in sweep_padlanes_groups.items():
        plot_sweep("PAD_LANES", (simd, pe), data, dir_padlanes)

    print("\nAll plots generated successfully!")

if __name__ == "__main__":
    main()