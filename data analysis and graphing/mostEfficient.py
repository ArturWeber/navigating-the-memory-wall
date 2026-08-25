#!/usr/bin/env python3
import csv
from pathlib import Path
from collections import defaultdict

# ---- Constants ----
CSV_PATH = Path("analysis/hardware_synthesis.csv")
OUT_DIR = Path("analysis_efficiency_lists")

def main():
    if not CSV_PATH.exists():
        raise SystemExit(f"ERROR: Cannot find {CSV_PATH}.")

    unique_configs = {}

    # 1. Read and Deduplicate Data
    with CSV_PATH.open("r", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Skip rows missing critical data
            if not (row.get("PT_FMAX_HZ") and row.get("PT_Power_Total_W") and
                    row.get("Area_Combinational") and row.get("Area_Noncombinational")):
                continue

            simd = int(row["SIMD"])
            pe = int(row["PE"])
            pad_lanes = int(row["MAX_INP_DIM_bytes"])
            max_inp_channels = pad_lanes // 9
            fmax_hz = float(row["PT_FMAX_HZ"])
            fmax_mhz = fmax_hz / 1e6
            power_w = float(row["PT_Power_Total_W"])
            power_uw = power_w * 1e6
            area_comb = float(row["Area_Combinational"])
            area_noncomb = float(row["Area_Noncombinational"])

            key = (simd, pe, pad_lanes)

            # Keep only the configuration with the highest FMAX
            if key not in unique_configs or fmax_hz > unique_configs[key]['fmax_hz']:
                unique_configs[key] = {
                    'simd': simd,
                    'pe': pe,
                    'pad_lanes': pad_lanes,
                    'max_inp_channels': max_inp_channels,
                    'fmax_hz': fmax_hz,
                    'fmax_mhz': fmax_mhz,
                    'power_w': power_w,
                    'power_uw': power_uw,
                    'area_comb': area_comb,
                    'area_noncomb': area_noncomb
                }

        # 2. Calculate Metrics
    processed_data = []
    for data in unique_configs.values():
        total_area = data['area_comb'] + data['area_noncomb']
        # CORRECTED: Physical cycle model
        fold_qnt = data['pad_lanes'] // data['simd']
        gmacs = (data['pe'] * data['pad_lanes'] * data['fmax_hz']) / (1e9 * (2 + data['pe'] * fold_qnt))
        gmacs_power = gmacs / data['power_w'] if data['power_w'] > 0 else 0
        gmacs_area = gmacs / total_area if total_area > 0 else 0

        processed_data.append({
            'GMAC/s': gmacs,
            'PT_Power_Total_uW': data['power_uw'],
            'Total_Area_um2': total_area,
            'GMAC/s_per_uW': gmacs / data['power_uw'] if data['power_uw'] > 0 else 0,
            'GMAC/s_per_Area_um2': gmacs_area,
            'SIMD': data['simd'],
            'PAD_LANES': data['pad_lanes'],
            'MAX_INP_CHANNELS': data['max_inp_channels'],
            'PE': data['pe'],
            'PT_FMAX_MHZ': data['fmax_mhz'],
            'Power_Efficiency_Rank': None,
            'Area_Efficiency_Rank': None
        })

    # 3. Sort Data and assign global ranks
    power_list = sorted(processed_data, key=lambda x: x['GMAC/s_per_uW'], reverse=True)
    area_list = sorted(processed_data, key=lambda x: x['GMAC/s_per_Area_um2'], reverse=True)

    # Assign ranks (1-based)
    for i, entry in enumerate(power_list):
        entry['Power_Efficiency_Rank'] = i + 1
    for i, entry in enumerate(area_list):
        entry['Area_Efficiency_Rank'] = i + 1

    # 4. Output Results to CSV (all fieldnames in ALL tables)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    common_fieldnames = [
        'GMAC/s', 'PT_Power_Total_uW', 'Total_Area_um2', 'GMAC/s_per_uW',
        'GMAC/s_per_Area_um2', 'SIMD', 'PAD_LANES', 'MAX_INP_CHANNELS',
        'PE', 'PT_FMAX_MHZ', 'Power_Efficiency_Rank', 'Area_Efficiency_Rank'
    ]

    power_csv = OUT_DIR / "most_efficient_power.csv"
    area_csv = OUT_DIR / "most_efficient_area.csv"

    with power_csv.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=common_fieldnames)
        writer.writeheader()
        writer.writerows(power_list)

    with area_csv.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=common_fieldnames)
        writer.writeheader()
        writer.writerows(area_list)

    ##### 5. Most efficient (PAD_LANES, PE) for area and power #####
    best_area_per_pair = {}
    for entry in area_list:
        key = (entry['PAD_LANES'], entry['PE'])
        if key not in best_area_per_pair:
            best_area_per_pair[key] = entry

    best_power_per_pair = {}
    for entry in power_list:
        key = (entry['PAD_LANES'], entry['PE'])
        if key not in best_power_per_pair:
            best_power_per_pair[key] = entry

    best_area_per_pair_list = sorted(best_area_per_pair.values(), key=lambda x: x['GMAC/s_per_Area_um2'], reverse=True)
    best_power_per_pair_list = sorted(best_power_per_pair.values(), key=lambda x: x['GMAC/s_per_uW'], reverse=True)

    def print_table(title, data_list, efficiency_field, rank_field):
        print(f"\n{'='*160}")
        print(f" {title}")
        print(f"{'='*160}")
        header = (
            f"{'GMAC/s':>8} | {'Power (μW)':>12} | {'Area ($μm^2$)':>14} | "
            f"{'GMAC/μW':>10} | {'GMAC/Area':>10} | {'SIMD':>4} | {'PAD_LANES':>9} | "
            f"{'MAX_INP_CH':>11} | {'PE':>4} | {'FMAX (MHz)':>12} | {'PowerRank':>9} | {'AreaRank':>8}"
        )
        print(header)
        print("-" * 160)
        for d in data_list[:10]:
            print(
                f"{d['GMAC/s']:8.2f} | "
                f"{int(round(d['PT_Power_Total_uW'])):12d} | "
                f"{int(round(d['Total_Area_um2'])):14,d} | "
                f"{d['GMAC/s_per_uW']:10.4f} | "
                f"{d['GMAC/s_per_Area_um2']:.2e} | "
                f"{d['SIMD']:4d} | "
                f"{d['PAD_LANES']:9d} | "
                f"{d['MAX_INP_CHANNELS']:11d} | "
                f"{d['PE']:4d} | "
                f"{d['PT_FMAX_MHZ']:12.2f} | "
                f"{d['Power_Efficiency_Rank'] if d['Power_Efficiency_Rank'] is not None else '':9} | "
                f"{d['Area_Efficiency_Rank'] if d['Area_Efficiency_Rank'] is not None else '':8}"
            )

    print_table("TOP 10 CONFIGURATIONS BY POWER EFFICIENCY (GMAC/s / μW)", power_list, 'GMAC/s_per_uW', 'Power_Efficiency_Rank')
    print_table(r"TOP 10 CONFIGURATIONS BY AREA EFFICIENCY (GMAC/s / $\mu m^2$)", area_list, 'GMAC/s_per_Area_um2', 'Area_Efficiency_Rank')
    print_table("PER (PAD_LANES, PE): MOST AREA EFFICIENT", best_area_per_pair_list, 'GMAC/s_per_Area_um2', 'Area_Efficiency_Rank')
    print_table("PER (PAD_LANES, PE): MOST POWER EFFICIENT", best_power_per_pair_list, 'GMAC/s_per_uW', 'Power_Efficiency_Rank')

    area_perpair_csv = OUT_DIR / "most_efficient_area_per_PADLANES_PE.csv"
    power_perpair_csv = OUT_DIR / "most_efficient_power_per_PADLANES_PE.csv"
    with area_perpair_csv.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=common_fieldnames)
        writer.writeheader()
        writer.writerows(best_area_per_pair_list)
    with power_perpair_csv.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=common_fieldnames)
        writer.writeheader()
        writer.writerows(best_power_per_pair_list)

    # Per-(PAD_LANES, PE) detail files
    combos = defaultdict(list)
    for entry in area_list:
        combos[(entry['PAD_LANES'], entry['PE'])].append(entry)
    for (pad, pe), rows in combos.items():
        fname = OUT_DIR / (f"most_efficient_area_PADLANES{pad}-PE{pe}.csv")
        with fname.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=common_fieldnames)
            writer.writeheader()
            writer.writerows(rows)
    combos_power = defaultdict(list)
    for entry in power_list:
        combos_power[(entry['PAD_LANES'], entry['PE'])].append(entry)
    for (pad, pe), rows in combos_power.items():
        fname = OUT_DIR / (f"most_efficient_power_PADLANES{pad}-PE{pe}.csv")
        with fname.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=common_fieldnames)
            writer.writeheader()
            writer.writerows(rows)

    ##############  PER PE: NEW DEDUPLICATED BLOCK  ##################
    pe_area_groups = defaultdict(list)
    pe_power_groups = defaultdict(list)
    for entry in area_list:
        pe_area_groups[entry['PE']].append(entry)
    for entry in power_list:
        pe_power_groups[entry['PE']].append(entry)
    # Write per-PE CSVs (area), dedup by PAD_LANES
    for pe, area_entries in pe_area_groups.items():
        best_per_padlanes = {}
        for entry in area_entries:
            pad = entry['PAD_LANES']
            if pad not in best_per_padlanes or entry['GMAC/s_per_Area_um2'] > best_per_padlanes[pad]['GMAC/s_per_Area_um2']:
                best_per_padlanes[pad] = entry
        sorted_entries = sorted(best_per_padlanes.values(), key=lambda x: x['GMAC/s_per_Area_um2'], reverse=True)
        fname = OUT_DIR / (f"most_efficient_area_PE{pe}.csv")
        with fname.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=common_fieldnames)
            writer.writeheader()
            writer.writerows(sorted_entries)
    # Write per-PE CSVs (power), dedup by PAD_LANES
    for pe, power_entries in pe_power_groups.items():
        best_per_padlanes = {}
        for entry in power_entries:
            pad = entry['PAD_LANES']
            if pad not in best_per_padlanes or entry['GMAC/s_per_uW'] > best_per_padlanes[pad]['GMAC/s_per_uW']:
                best_per_padlanes[pad] = entry
        sorted_entries = sorted(best_per_padlanes.values(), key=lambda x: x['GMAC/s_per_uW'], reverse=True)
        fname = OUT_DIR / (f"most_efficient_power_PE{pe}.csv")
        with fname.open("w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=common_fieldnames)
            writer.writeheader()
            writer.writerows(sorted_entries)
    ##############  END PER PE BLOCK  ###################

    print(f"\n[SUCCESS] Full lists saved to:")
    print(f"  - {power_csv}")
    print(f"  - {area_csv}")
    print(f"  - {area_perpair_csv}")
    print(f"  - {power_perpair_csv}")
    print(f"    ... and {len(combos)} area and {len(combos_power)} power CSVs by PAD_LANES-PE.")
    print(f"    ... and {len(pe_area_groups)} (area) and {len(pe_power_groups)} (power) CSVs by PE.\n")

if __name__ == "__main__":
    main()