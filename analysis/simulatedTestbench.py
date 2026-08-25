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

    # 5. Generate Continuous Lines for the Background (Cycle-Accurate Alignment)
    oi_range = np.logspace(np.log2(0.5), np.log2(args.pe * 2), num=500, base=2.0)
    
    roof_compute = []
    roof_lat_only = []
    roof_bw_only = []
    roof_memory = []

    for oi_val in oi_range:
        macs_val = oi_val * s_in_bytes
        
        # Back-calculate pe_qnt from OI to match discrete simulation mapping
        pe_qnt_continuous = (oi_val * s_in_bytes) / (args.simd * fold_qnt)
        
        # Cycle-accurate compute time
        tcomp_c_cont = 2 + (pe_qnt_continuous * fold_qnt)
        tcomp_s_effective = tcomp_c_cont / fclk_hz  
        
        # Cycle-accurate memory time
        tlat_s = args.lat
        tbw_s = s_in_bytes / (args.bw * 1e9)
        tmem_s = tlat_s + tbw_s
        tmem_c = sec_to_cycles(tmem_s, fclk_hz)
        tmem_s_effective = tmem_c / fclk_hz
        
        # The Cycle-Accurate Performances (GMAC/s)
        roof_compute.append((macs_val / 1e9) / tcomp_s_effective)
        roof_memory.append((macs_val / 1e9) / tmem_s_effective)
        
        # Raw physical limits for visual context (no ceil needed for the abstract limits)
        roof_bw_only.append((macs_val / 1e9) / tbw_s)
        if tlat_s > 0:
            roof_lat_only.append((macs_val / 1e9) / tlat_s)
        else:
            roof_lat_only.append(float('inf'))

    # 5.5 Generate the Red Line (Roofline Envelope) specifically bounded from PE=1 to PE=MAX
    oi_range_red = np.linspace(sim_oi[0], sim_oi[-1], 500)
    roofline_red = []
    
    for oi_val in oi_range_red:
        macs_val = oi_val * s_in_bytes
        pe_qnt_continuous = (oi_val * s_in_bytes) / (args.simd * fold_qnt)
        
        tcomp_c_cont = 2 + (pe_qnt_continuous * fold_qnt)
        tmem_s = args.lat + (s_in_bytes / (args.bw * 1.0e9))
        tmem_c = sec_to_cycles(tmem_s, fclk_hz)
        
        total_cycles = max(tmem_c, tcomp_c_cont)
        perf = (macs_val / 1e9) / (total_cycles / fclk_hz)
        roofline_red.append(perf)

    # 6. Plotting the Roofline
    plt.figure(figsize=(10, 7))
    
    plt.plot(oi_range, roof_compute, 'k--', label="Compute Roof", linewidth=2)
    plt.plot(oi_range, roof_lat_only, 'g:', label="Latency Roof", linewidth=1.5, alpha=0.5)
    plt.plot(oi_range, roof_bw_only, 'm:', label="Bandwidth Roof", linewidth=1.5, alpha=0.5)
    plt.plot(oi_range, roof_memory, 'b--', label="Memory Roof", linewidth=2)
    
    # Plot the Cycle-Accurate Red Envelope strictly bounded to X-axis PE range
    plt.plot(oi_range_red, roofline_red, 'r-', label="Roofline Envelope", linewidth=3)
    
    # Plot Simulated Data Points FIRST (so we can use them for bounds)
    plt.scatter(sim_oi, sim_gmacs, c='orange', edgecolor='black', zorder=5, s=60, label="MVU Streaming-State Points")
    
    # Ridge Point and Always-Bound Logic
    arr_compute = np.array(roof_compute)
    arr_memory = np.array(roof_memory)
    idx = np.argmin(np.abs(arr_compute - arr_memory))
    ridge_oi = oi_range[idx]
    ridge_perf = arr_compute[idx]

    # Determine which bound dominates across the operational range with hardware-accurate rounding
    min_oi_idx = 0
    max_oi_idx = len(sim_oi) - 1
    
    # Cycle representations for boundary checks
    tcomp_min_c = 2 + (1 * fold_qnt)
    tcomp_max_c = 2 + (args.pe * fold_qnt)
    
    tmem_s_raw = args.lat + (s_in_bytes / (args.bw * 1e9))
    tmem_c_rounded = sec_to_cycles(tmem_s_raw, fclk_hz)
    
    always_compute_bound = (tcomp_min_c >= tmem_c_rounded) and (tcomp_max_c >= tmem_c_rounded)
    always_memory_bound = (tmem_c_rounded >= tcomp_min_c) and (tmem_c_rounded >= tcomp_max_c)

    # Set y-axis limits BEFORE placing annotations
    y_min = min(sim_gmacs) * 0.6
    
    # Filter out infinities for robust y_max boundary calculation 
    valid_lat = [v for v in roof_lat_only if v != float('inf')]
    max_lat = max(valid_lat) if valid_lat else 0
    valid_bw = [v for v in roof_bw_only if v != float('inf')]
    max_bw = max(valid_bw) if valid_bw else 0
    
    y_max = max(max(roof_compute), max(roof_memory), max_lat, max_bw, max(sim_gmacs)) * 1.4
    plt.ylim(y_min, y_max)
    
    # Now place annotations with proper coordinates
    if always_compute_bound:
        # Always Compute Bound -> bottom left
        plt.text(oi_range[0]*1.15, y_min * 1.4, 
                 'ALWAYS COMPUTE BOUND',
                 fontsize=11, color='black', fontweight='bold',
                 verticalalignment='bottom', horizontalalignment='left')
    elif always_memory_bound:
        # Always Memory Bound -> bottom right
        plt.text(oi_range[-1]*0.85, y_min * 1.4, 
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
    
    plt.xlabel("Operational Intensity (MAC/Byte)")
    plt.ylabel("Performance (GMAC/s)")
    plt.legend(loc="upper left")

    filename = f"sim_simd{args.simd}_pe{args.pe}_maxchannels{args.maxch}_tgtclkfreq{tgt_freq_hz:g}_bw{args.bw}_lat{args.lat}_fclkused{fclk_hz:.4f}.png"
    filepath = OUT_DIR / filename
    plt.savefig(filepath, dpi=300, bbox_inches='tight')
    print(f"\nPlot saved to: {filepath}")
    
if __name__ == "__main__":
    main()