#!/usr/bin/env python3
import re
import csv
import math
from pathlib import Path

# ---- Assumptions (edit if needed) ----
KERNEL_X = 3
KERNEL_Y = 3
DATA_WIDTH_BITS = 8  # if int8, bytes-per-lane = 1
# --------------------------------------

RESULTS_DIR = Path("results")
OUT_DIR = Path("analysis")
OUT_DIR.mkdir(parents=True, exist_ok=True)

# example: simd512_pe32_maxchannels56_tgtclkfreq7e7
PAT = re.compile(
    r"^simd(?P<simd>\d+)_pe(?P<pe>\d+)_maxchannels(?P<maxch>\d+)_tgtclkfreq(?P<freq>[\deE\+\-\.]+)$"
)

def lcm(a: int, b: int) -> int:
    return abs(a * b) // math.gcd(a, b) if a and b else 0

def get_report_file(directory, base_name):
    """Helper function to find a file even if the OS appends .txt or .rpt"""
    for ext in ["", ".rpt", ".txt"]:
        f = directory / f"{base_name}{ext}"
        if f.exists():
            return f
    return None

def main():
    if not RESULTS_DIR.exists():
        raise SystemExit(f"ERROR: '{RESULTS_DIR}' not found. Run from repo root.")

    bytes_per_lane = DATA_WIDTH_BITS // 8
    if DATA_WIDTH_BITS % 8 != 0:
        raise SystemExit("ERROR: DATA_WIDTH_BITS must be a multiple of 8 to report bytes cleanly.")

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
        tgt_freq_hz = float(m.group("freq"))

        dot_lanes = maxch * KERNEL_X * KERNEL_Y  # MAX_CHANNELS * 9
        pad_lanes = ((dot_lanes + simd - 1) // simd) * simd
        max_inp_dim_bytes = pad_lanes * bytes_per_lane

        # Initialize dictionary with strictly independent base values
        row_data = {
            "SIMD": simd,
            "MAX_INP_DIM_bytes": int(max_inp_dim_bytes),
            "PE": pe,
            "TARGET_FREQUENCY_HZ": int(tgt_freq_hz) if tgt_freq_hz.is_integer() else tgt_freq_hz,
            "Count_Ports": None,
            "Count_Nets": None,
            "Count_Cells": None,
            "Count_Combi_Cells": None,
            "Count_Seq_Cells": None,
            "Area_Combinational": None,
            "Area_Noncombinational": None,
            "Area_Net_Interconnect": None,
            "BLK_WEIGHTS_Area_Combinational": None,
            "BLK_WEIGHTS_Area_Noncombinational": None,
            "PT_FMAX_HZ": None,
            "PT_Power_Int_W": None,
            "PT_Power_Switch_W": None,
            "PT_Power_Leak_W": None,
            "PT_Power_Total_W": None,
        }

        # ---------------------------------------------------------
        # 1. Design Compiler (DC) Area Extraction
        # ---------------------------------------------------------
        area_file = get_report_file(p / "dc", f"area_hier_{p.name}")
        if area_file:
            text = area_file.read_text(encoding="utf-8", errors="ignore")
            
            def extract_int(pattern):
                match = re.search(pattern, text)
                return int(match.group(1)) if match else None
                
            def extract_float(pattern):
                match = re.search(pattern, text)
                return float(match.group(1)) if match else None

            # Extract counts and global areas
            row_data["Count_Ports"] = extract_int(r"Number of ports:\s+(\d+)")
            row_data["Count_Nets"] = extract_int(r"Number of nets:\s+(\d+)")
            row_data["Count_Cells"] = extract_int(r"Number of cells:\s+(\d+)")
            row_data["Count_Combi_Cells"] = extract_int(r"Number of combinational cells:\s+(\d+)")
            row_data["Count_Seq_Cells"] = extract_int(r"Number of sequential cells:\s+(\d+)")
            
            row_data["Area_Combinational"] = extract_float(r"Combinational area:\s+([\d\.]+)")
            row_data["Area_Noncombinational"] = extract_float(r"Noncombinational area:\s+([\d\.]+)")
            row_data["Area_Net_Interconnect"] = extract_float(r"Net Interconnect area:\s+([\d\.]+)")
            
            # BLK_WEIGHTS extraction
            m_blk = re.search(r"^\s*BLK_WEIGHTS\s+[\d\.]+\s+[\d\.]+\s+([\d\.]+)\s+([\d\.]+)", text, re.MULTILINE)
            if m_blk:
                row_data["BLK_WEIGHTS_Area_Combinational"] = float(m_blk.group(1))
                row_data["BLK_WEIGHTS_Area_Noncombinational"] = float(m_blk.group(2))

        # ---------------------------------------------------------
        # 2. PrimeTime (PT) Timing Extraction -> FMAX
        # ---------------------------------------------------------
        # Look for the timing report file
        timing_file = get_report_file(p / "pt", f"critical_path_target_{p.name}")
        if timing_file:
            text = timing_file.read_text(encoding="utf-8", errors="ignore")
            
            # Grabs the value at the very end of the 'data arrival time' line
            m_crit = re.search(r"data arrival time\s+([\d\.]+)", text)
            if m_crit:
                crit_path_ns = float(m_crit.group(1))
                if crit_path_ns > 0:
                    # Calculate FMAX in Hz: 1 / (Critical Path in nanoseconds)
                    row_data["PT_FMAX_HZ"] = int(1e9 / crit_path_ns)

        # ---------------------------------------------------------
        # 3. PrimeTime (PT) Power at FMAX Extraction
        # ---------------------------------------------------------
        pwr_file = get_report_file(p / "pt", f"power_fmax_{p.name}")
        if pwr_file:
            text = pwr_file.read_text(encoding="utf-8", errors="ignore")
            
            # Extracts the 4 floats on the 'pe' line (Int, Switch, Leak, Total)
            m_pwr = re.search(r"^\s*pe\s+([\d\.eE\+\-]+)\s+([\d\.eE\+\-]+)\s+([\d\.eE\+\-]+)\s+([\d\.eE\+\-]+)", text, re.MULTILINE)
            if m_pwr:
                row_data["PT_Power_Int_W"] = float(m_pwr.group(1))
                row_data["PT_Power_Switch_W"] = float(m_pwr.group(2))
                row_data["PT_Power_Leak_W"] = float(m_pwr.group(3))
                row_data["PT_Power_Total_W"] = float(m_pwr.group(4))

        rows.append(row_data)

    if not rows:
        raise SystemExit("No matching hardware-id folders found under results/.")

    # Sort by the parameters requested
    rows.sort(key=lambda r: (r["SIMD"], r["MAX_INP_DIM_bytes"], r["PE"], float(r["TARGET_FREQUENCY_HZ"])))

    out_csv = OUT_DIR / "hardware_synthesis.csv"
    
    # Preserve key order for CSV headers
    fieldnames = list(row_data.keys())
    
    with out_csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        w.writerows(rows)

    print(f"Wrote {out_csv} ({len(rows)} rows).")

if __name__ == "__main__":
    main()