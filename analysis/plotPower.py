#!/usr/bin/env python3
import csv
import matplotlib.pyplot as plt
from pathlib import Path
from collections import defaultdict

# ---- Constants ----
CSV_PATH = Path("analysis/hardware_synthesis.csv")

# Set global font: Times New Roman, larger
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

def plot_power_sweep(sweep_mode, fixed_vars, group_data, out_dir):
    # Sort data by X-axis to draw lines cleanly left-to-right
    group_data.sort(key=lambda item: item[0])
    
    x_vals = [d[0] for d in group_data]
    pwr_int = [d[1] for d in group_data]
    pwr_switch = [d[2] for d in group_data]
    pwr_leak = [d[3] for d in group_data]
    pwr_total = [d[4] for d in group_data]

    # Set up axis labels and filename
    if sweep_mode == "SIMD":
        pe_val, padlanes_val = fixed_vars
        xlabel = 'SIMD Size'
        legend_str = f"PE = {pe_val}, PAD_LANES = {padlanes_val}"
        filename = f"power_sweep_SIMD_pe{pe_val}_padlanes{padlanes_val}.png"
    elif sweep_mode == "PE":
        simd_val, padlanes_val = fixed_vars
        xlabel = 'PE Size'
        legend_str = f"SIMD = {simd_val}, PAD_LANES = {padlanes_val}"
        filename = f"power_sweep_PE_simd{simd_val}_padlanes{padlanes_val}.png"
    else:  # PAD_LANES
        simd_val, pe_val = fixed_vars
        xlabel = 'PAD_LANES'
        legend_str = f"SIMD = {simd_val}, PE = {pe_val}"
        filename = f"power_sweep_PADLANES_simd{simd_val}_pe{pe_val}.png"

    # Plotting (Single Axis because all units are Watts)
    fig, ax = plt.subplots(figsize=(10, 6))

    # Plot the components (dashed lines)
    ax.plot(x_vals, pwr_int, color='tab:blue', linestyle='--', marker='o', linewidth=2, label="Internal Power")
    ax.plot(x_vals, pwr_switch, color='tab:orange', linestyle='--', marker='s', linewidth=2, label="Switching Power")
    ax.plot(x_vals, pwr_leak, color='tab:green', linestyle='--', marker='^', linewidth=2, label="Leakage Power")
    # Plot Total Power (Thick, continuous line)
    ax.plot(x_vals, pwr_total, color='tab:red', linestyle='-', marker='D', linewidth=4, label="Total Power")

    # --- Formatting ---
    ax.set_xlabel(xlabel, fontweight='bold')
    ax.set_ylabel('Power (Watts)', fontweight='bold')

    # Handle Log scale safely
    if len(x_vals) > 1:
        ax.set_xscale('log', base=2)
    else:
        ax.set_xlim(x_vals[0] * 0.8, x_vals[0] * 1.2)

    ax.set_xticks(x_vals)
    ax.set_xticklabels([str(x) for x in x_vals])
    ax.grid(True, which="both", ls="--", alpha=0.5)
    ax.set_ylim(bottom=0)

    ax.legend(loc='upper left', framealpha=0.9, edgecolor='gray')

    fig.tight_layout()

    filepath = out_dir / filename
    plt.savefig(filepath, dpi=300)
    plt.close(fig)
    print(f"Saved: {out_dir.name}/{filename} ({len(x_vals)} points)")

def main():
    if not CSV_PATH.exists():
        raise SystemExit(f"ERROR: Cannot find {CSV_PATH}.")

    # 1. Create Output Directories
    dir_simd = Path("powerPlotperSIMD")
    dir_pe = Path("powerPlotperPE")
    dir_padlanes = Path("powerPlotperPAD_LANES")
    
    for d in [dir_simd, dir_pe, dir_padlanes]:
        d.mkdir(parents=True, exist_ok=True)

    # 2. Extract and Deduplicate Data
    unique_configs = {}
    with CSV_PATH.open("r", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Check if synthesis succeeded and power data exists
            if (row["PT_FMAX_HZ"] and row["PT_Power_Total_W"] and
                row["PT_Power_Int_W"] and row["PT_Power_Switch_W"] and row["PT_Power_Leak_W"]):

                simd = int(row["SIMD"])
                pe = int(row["PE"])
                padlanes = int(row["MAX_INP_DIM_bytes"])  # now PAD_LANES
                fmax = float(row["PT_FMAX_HZ"])

                pwr_int = float(row["PT_Power_Int_W"])
                pwr_switch = float(row["PT_Power_Switch_W"])
                pwr_leak = float(row["PT_Power_Leak_W"])
                pwr_total = float(row["PT_Power_Total_W"])

                key = (simd, pe, padlanes)
                # If first time seeing this config, or this run had better Fmax
                if key not in unique_configs or fmax > unique_configs[key][0]:
                    unique_configs[key] = (fmax, pwr_int, pwr_switch, pwr_leak, pwr_total)

    print(f"Found {len(unique_configs)} unique valid hardware configurations in CSV.\n")

    sweep_simd_groups = defaultdict(list)
    sweep_pe_groups = defaultdict(list)
    sweep_padlanes_groups = defaultdict(list)
    for (simd, pe, padlanes), data in unique_configs.items():
        _, pwr_int, pwr_switch, pwr_leak, pwr_total = data
        # Store as: (Sweep_Variable, Int, Switch, Leak, Total)
        sweep_simd_groups[(pe, padlanes)].append((simd, pwr_int, pwr_switch, pwr_leak, pwr_total))
        sweep_pe_groups[(simd, padlanes)].append((pe, pwr_int, pwr_switch, pwr_leak, pwr_total))
        sweep_padlanes_groups[(simd, pe)].append((padlanes, pwr_int, pwr_switch, pwr_leak, pwr_total))

    print("--- Generating Power SIMD Sweeps ---")
    for (pe, padlanes), data in sweep_simd_groups.items():
        plot_power_sweep("SIMD", (pe, padlanes), data, dir_simd)

    print("\n--- Generating Power PE Sweeps ---")
    for (simd, padlanes), data in sweep_pe_groups.items():
        plot_power_sweep("PE", (simd, padlanes), data, dir_pe)

    print("\n--- Generating Power PAD_LANES Sweeps ---")
    for (simd, pe), data in sweep_padlanes_groups.items():
        plot_power_sweep("PAD_LANES", (simd, pe), data, dir_padlanes)

    print("\nAll Power plots generated successfully!")

if __name__ == "__main__":
    main()