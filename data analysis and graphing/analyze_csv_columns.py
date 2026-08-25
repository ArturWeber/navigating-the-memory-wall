#!/usr/bin/env python3
import csv
import matplotlib.pyplot as plt
import argparse
import statistics
from bisect import bisect_left

def percentile(sorted_vals, p):
    """Return the value at percentile p [0-100] of a sorted list."""
    if not sorted_vals:
        return None
    k = (len(sorted_vals)-1) * (p/100.0)
    f = int(k)
    c = min(f+1, len(sorted_vals)-1)
    if f == c:
        return sorted_vals[f]
    else:
        d0 = sorted_vals[f] * (c-k)
        d1 = sorted_vals[c] * (k-f)
        return d0 + d1

def main():
    parser = argparse.ArgumentParser(description='Column stats for a CSV (no pandas).')
    parser.add_argument('csv', help='CSV file to analyze')
    parser.add_argument('column', help='Column name to process (as in header)')
    parser.add_argument('--bins', type=int, default=15, help='Number of histogram bins')
    args = parser.parse_args()

    vals = []
    with open(args.csv, newline='') as f:
        reader = csv.DictReader(f)
        if args.column not in reader.fieldnames:
            print(f"ERROR: Column '{args.column}' not in CSV. Available: {reader.fieldnames}")
            exit(1)
        for row in reader:
            v = row[args.column]
            try:
                vals.append(float(v))
            except (ValueError, TypeError):
                continue

    if not vals:
        print("No valid numeric data found.")
        return
    sorted_vals = sorted(vals)
    mean = statistics.mean(vals)
    median = statistics.median(vals)
    std = statistics.stdev(vals) if len(vals)>1 else 0.0
    minv = min(vals)
    maxv = max(vals)
    p25 = percentile(sorted_vals, 25)
    p75 = percentile(sorted_vals, 75)

    print(f"\n=== Statistics for '{args.column}' ===")
    print(f"Mean:    {mean:.4f}")
    print(f"Median:  {median:.4f}")
    print(f"Stddev:  {std:.4f}")
    print(f"Min:     {minv:.4f}")
    print(f"Max:     {maxv:.4f}")
    print(f"25%ile:  {p25:.4f}")
    print(f"75%ile:  {p75:.4f}")
    print(f"N:       {len(vals)}")

    # Histogram
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

    plt.figure(figsize=(7,5))
    plt.hist(vals, bins=80, alpha=0.75, edgecolor='black')
    plt.axvline(mean, color='red', linestyle='dashed', linewidth=2, label=f"Mean = {mean:.2f}")
    plt.axvline(median, color='green', linestyle='dashed', linewidth=2, label=f"Median = {median:.2f}")
    plt.xlabel(args.column)
    plt.ylabel("Count")
    plt.legend()
    plt.tight_layout()
    plt.show()

if __name__ == "__main__":
    main()