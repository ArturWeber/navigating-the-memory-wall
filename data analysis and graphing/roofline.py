#!/usr/bin/env python3
import csv
import math
import argparse
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path

# ---- Constants ----
KERNEL_X = 3
KERNEL_Y = 3
DATA_WIDTH_BITS = 8
BYTES_PER_LANE = DATA_WIDTH_BITS // 8
CSV_PATH = Path("analysis/hardware_synthesis.csv")
OUT_DIR = Path("rooflines")

def sec_to_cycles(time_sec, fclk_hz):
    """Matches the Verilog sec_to_cycles rounding logic (ceiling)"""
    return math.ceil(time_sec * fclk_hz)

def main():
    parser = argparse.ArgumentParser(description="Extended Roofline Generator (Log2-Log2)")
    parser.add_argument("--simd", type=int, required=True, help="SIMD width")
    parser.add_argument("--maxch", type=int, required=True, help="Maximum Input Channels")
    parser.add_argument("--pe", type=int, required=True, help="Maximum Hardware Output Channels (PE)")
    parser.add_argument("--bw", type=float, required=True, help="Memory Bandwidth in GB/s")
    parser.add_argument("--lat", type=float, required=True, help="Memory Latency in seconds (e.g. 100e-9)")
    
    args = parser.parse_args()

    # 1. Ensure Output Directory
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    # 2. Lookup Frequencies from CSV
    if not CSV_PATH.exists():
        raise SystemExit(f"ERROR: Cannot find {CSV_PATH}. Run the synthesis extractor first.")
        
    fclk_hz = None
    tgt_freq_hz = None
    
    with CSV_PATH.open("r", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if (int(row["SIMD"]) == args.simd and int(row["PE"]) == args.pe):
                
                # Verify MAX_INP_DIM_bytes matches the requested max channels
                dot_lanes = args.maxch * KERNEL_X * KERNEL_Y
                pad_lanes = ((dot_lanes + args.simd - 1) // args.simd) * args.simd
                expected_bytes = pad_lanes * BYTES_PER_LANE
                
                if int(row["MAX_INP_DIM_bytes"]) == expected_bytes:
                    tgt_freq_hz = float(row["TARGET_FREQUENCY_HZ"])
                    if row["PT_FMAX_HZ"]:
                        fclk_hz = float(row["PT_FMAX_HZ"])
                    break
                    
    if fclk_hz is None or tgt_freq_hz is None:
        raise SystemExit(f"ERROR: Could not find matching hardware in CSV for SIMD={args.simd}, PE={args.pe}, MAXCH={args.maxch}")

    print(f"Hardware Found! Target Freq = {tgt_freq_hz/1e6:.1f} MHz | Actual FMAX = {fclk_hz/1e6:.2f} MHz")

    # 3. Architectural Constants
    dot_lanes = args.maxch * KERNEL_X * KERNEL_Y
    fold_qnt = math.ceil(dot_lanes / args.simd)
    s_in_bytes = fold_qnt * args.simd * BYTES_PER_LANE

    # Lists to hold scatter plot data
    sim_oi = []
    sim_gmacs = []

    print("\n--- Sweeping Output Channels (pe_qnt) ---")
    
    # 4. Discrete Pipeline Simulation (Sweeping pe_qnt from 1 to PE)
    for pe_qnt in range(1, args.pe + 1):
        macs = pe_qnt * args.simd * fold_qnt
        oi = macs / s_in_bytes
        
        # Memory cycles (T_mem = T_lat + T_bw)
        tmem_s = args.lat + (s_in_bytes / (args.bw * 1.0e9))
        tmem_c = sec_to_cycles(tmem_s, fclk_hz)
        
        # Compute cycles (T_comp)
        tcomp_c = 2 + (pe_qnt * fold_qnt)
        
        # Roofline logic: max(T_mem, T_comp)
        total_cycles_steady = max(tmem_c, tcomp_c)
        
        gmacs_t = (macs / 1.0e9) / (total_cycles_steady / fclk_hz)
        
        sim_oi.append(oi)
        sim_gmacs.append(gmacs_t)
        
        print(f"pe_qnt: {pe_qnt:2d} | OI: {oi:4.1f} MAC/B | T_mem: {tmem_c:4d} cyc | T_comp: {tcomp_c:4d} cyc | Perf: {gmacs_t:6.2f} GMAC/s")

    # 5. Generate Continuous Lines for the Background
    oi_range = np.logspace(np.log2(0.5), np.log2(args.pe * 2), num=500, base=2.0)
    
    roof_compute = []
    roof_lat_only = []
    roof_bw_only = []
    roof_memory = []
    roofline_final = []

    for oi_val in oi_range:
        macs_val = oi_val * s_in_bytes
        
        pe_qnt_continuous = (oi_val * s_in_bytes) / (args.simd * fold_qnt)
        
        # The Distinct Times (Seconds)
        tcomp_s = (2 + (pe_qnt_continuous * fold_qnt)) / fclk_hz  # Use pe_qnt, not oi_val
        tlat_s = args.lat
        tbw_s = s_in_bytes / (args.bw * 1e9)
        tmem_s = tlat_s + tbw_s
        
        # The Distinct Performances (GMAC/s)
        perf_comp = (macs_val / 1e9) / tcomp_s
        perf_lat = (macs_val / 1e9) / tlat_s
        perf_bw = (macs_val / 1e9) / tbw_s
        perf_mem = (macs_val / 1e9) / tmem_s
        perf_roof = (macs_val / 1e9) / max(tcomp_s, tmem_s)
        
        roof_compute.append(perf_comp)
        roof_lat_only.append(perf_lat)
        roof_bw_only.append(perf_bw)
        roof_memory.append(perf_mem)
        roofline_final.append(perf_roof)

    # 6. Plotting the Roofline
    plt.figure(figsize=(10, 7))
    
    # Extend the x-range for the theoretical roofs to show full context
    oi_extended = np.logspace(np.log2(0.3), np.log2(args.pe * 3), num=500, base=2.0)
    
    # Recalculate extended roofs for visualization
    roof_compute_ext = []
    roof_memory_ext = []
    
    for oi_val in oi_extended:
        macs_val = oi_val * s_in_bytes
        pe_qnt_continuous = (oi_val * s_in_bytes) / (args.simd * fold_qnt)
        
        tcomp_s = (2 + (pe_qnt_continuous * fold_qnt)) / fclk_hz
        tlat_s = args.lat
        tbw_s = s_in_bytes / (args.bw * 1e9)
        tmem_s = tlat_s + tbw_s
        
        perf_comp = (macs_val / 1e9) / tcomp_s
        perf_mem = (macs_val / 1e9) / tmem_s
        
        roof_compute_ext.append(perf_comp)
        roof_memory_ext.append(perf_mem)
    
    # Plot extended roofs
    plt.plot(oi_extended, roof_compute_ext, 'k--', label="Compute Roof", linewidth=2)
    plt.plot(oi_extended, roof_memory_ext, 'b--', label="Memory Roof", linewidth=2)
    
    # Plot the roofline envelope only over the operational range
    plt.plot(oi_range, roofline_final, 'r-', label="Roofline Envelope", linewidth=3)
    
    # Plot Simulated Data Points FIRST (so we can use them for bounds)
    plt.scatter(sim_oi, sim_gmacs, c='orange', edgecolor='black', zorder=5, s=60, label="MVU Streaming-State Points")
    
    # Ridge Point and Always-Bound Logic
    arr_compute = np.array(roof_compute)
    arr_memory = np.array(roof_memory)
    oi_array = np.array(oi_range)
    idx = np.argmin(np.abs(arr_compute - arr_memory))
    ridge_oi = oi_range[idx]
    ridge_perf = arr_compute[idx]

    # Determine which bound dominates across the operational range
    # Check at min and max OI points
    min_oi_idx = 0
    max_oi_idx = len(sim_oi) - 1
    
    # For minimum OI (pe_qnt=1)
    min_oi = sim_oi[min_oi_idx]
    macs_min = min_oi * s_in_bytes
    tcomp_min = (2 + (1 * fold_qnt)) / fclk_hz
    tmem = args.lat + (s_in_bytes / (args.bw * 1e9))
    
    # For maximum OI (pe_qnt=PE)
    max_oi = sim_oi[max_oi_idx]
    macs_max = max_oi * s_in_bytes
    tcomp_max = (2 + (args.pe * fold_qnt)) / fclk_hz
    
    always_compute_bound = (tcomp_min > tmem) and (tcomp_max > tmem)
    always_memory_bound = (tmem > tcomp_min) and (tmem > tcomp_max)

    # Set y-axis limits BEFORE placing annotations
    y_min = min(sim_gmacs) * 0.6
    y_max = max(max(roof_compute_ext), max(roof_memory_ext), max(sim_gmacs)) * 1.4
    plt.ylim(y_min, y_max)
    
    # Now place annotations with proper coordinates
    if always_compute_bound:
        # Always Compute Bound -> bottom left
        plt.text(oi_extended[0]*1.15, y_min * 1.4, 
                 'ALWAYS COMPUTE BOUND',
                 fontsize=11, color='black', fontweight='bold',
                 verticalalignment='bottom', horizontalalignment='left')
    elif always_memory_bound:
        # Always Memory Bound -> bottom right
        plt.text(oi_extended[-1]*0.85, y_min * 1.4, 
                 'ALWAYS MEMORY BOUND',
                 fontsize=11, color='black', fontweight='bold',
                 verticalalignment='bottom', horizontalalignment='right')
    else:
        # Usual case: show ridge point and vertical
        plt.scatter([ridge_oi], [ridge_perf], c='gray', s=120, zorder=10, edgecolors='white')
        
        # Place annotation inside the plot at a fixed relative position
        y_annot_pos = y_min * 2.5  # Fixed position above bottom
        
        plt.text(ridge_oi * 1.05, y_annot_pos,
                 f'Ridge Point\nOI = {ridge_oi:.2f}',
                 fontsize=10,
                 fontweight='bold',
                 color='gray',
                 verticalalignment='bottom',
                 horizontalalignment='left',
                 bbox=dict(facecolor='white', alpha=0.8, edgecolor='gray', pad=3, linewidth=1))
        plt.axvline(x=ridge_oi, color='gray', linestyle='--', alpha=0.4)
    
    # Formatting
    plt.xscale('log', base=2)
    plt.yscale('log', base=2)
    plt.grid(True, which="both", ls="--", alpha=0.5)
    
    plt.title(f"Extended Roofline Model\nSIMD={args.simd}, PE_MAX={args.pe}, BW={args.bw}GB/s, Lat={args.lat*1e9}ns\nFmax={fclk_hz/1e6:.1f}MHz")
    plt.xlabel("Operational Intensity (MAC/Byte)")
    plt.ylabel("Performance (GMAC/s)")
    plt.legend(loc="upper left")

    filename = f"sim_simd{args.simd}_pe{args.pe}_maxchannels{args.maxch}_tgtclkfreq{tgt_freq_hz:g}_bw{args.bw}_lat{args.lat}_fclkused{fclk_hz:.4f}.png"
    filepath = OUT_DIR / filename
    plt.savefig(filepath, dpi=300, bbox_inches='tight')
    print(f"\nPlot saved to: {filepath}")

if __name__ == "__main__":
    main()