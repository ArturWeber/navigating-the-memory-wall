# Navigating the Memory Wall

Design Space Exploration of bandwidth and latency constraints in SIMD neural accelerators using a weight-resident Matrix-Vector Unit (MVU), RTL synthesis, and Roofline-based analysis.

## 📄 Publications
- **Undergraduate Thesis (TCC):** <a href="docs/Full Thesis.pdf">docs/Full Thesis.pdf</a> — also on USP's BDTA *(link pending)*
- **Conference Paper:** <a href="docs/SForum Paper.pdf">docs/SForum Paper.pdf</a> — SForum, Chip in Sampa 2026 *(proceedings link pending, expected Sept 2026)*
  
## Contributors
- **Artur Brenner Weber** — author and main implementation/research lead
- **MSc. Eduardo Sperle Honorato** — foundational RTL/testbench baseline and methodological basis acknowledged in code/paper
- **Prof. Dr. Vanderlei Bonato** — advisor

## Key Results at a Glance

| Metric | Baseline Scale-Up Node ($PE=64, \text{SIMD}=512$) | Winning Balanced Node ($PE=8, \text{SIMD}=128$) | Distributed Scale-Out ($4\times \text{Balanced Nodes}$) |
| :--- | :---: | :---: | :---: |
| **Clock Frequency ($F_{max}$)** | 64.23 MHz | 254.45 MHz | 254.45 MHz |
| **Throughput (at 25 GB/s)** | 31.89 GMAC/s | 26.06 GMAC/s | 104.24 GMAC/s (+227%) |
| **Active Power** | 1,790.00 µW | 82.60 µW | 330.40 µW (-82%) |
| **Silicon Area (14nm)** | 489,212 µm² | 25,813 µm² | 103,252 µm² (-79%) |
| **Energy-Delay Product (EDP)** | $17.59 \times 10^{-13}\text{ J}\cdot\text{s}$ | $1.22 \times 10^{-13}\text{ J}\cdot\text{s}$ | $0.30 \times 10^{-13}\text{ J}\cdot\text{s}$ (58× better) |

## Motivation: The Empirical Memory Wall

Arithmetic arrays scale faster than memory hierarchies can deliver operands. In edge SoCs, this establishes data delivery—not compute density—as the primary bottleneck.

We observe this directly in commercial edge hardware. Benchmarking **Apple Silicon SoCs (M1–M5)** on memory-bound workloads (Blender OpenData) reveals that **binned chips (with deactivated GPU cores) consistently achieve higher per-core performance** than fully unlocked variants because fewer cores contend for the same unified memory bandwidth:

| Architecture Variant | GPU Cores | Total BW (GB/s) | BW / Core (GB/s) | Perf. / Core (Median Score) |
| :--- | :---: | :---: | :---: | :---: |
| **M3 (Binned)** | 8 | 100 | 12.50 | **109.45** |
| **M3 (Fully-enabled)** | 10 | 100 | 10.00 (-20.0%) | **92.17 (-15.8%)** |
| **M4 (Binned)** | 8 | 120 | 15.00 | **134.07** |
| **M4 (Fully-enabled)** | 10 | 120 | 12.00 (-20.0%) | **108.79 (-18.9%)** |
| **M5 (Binned)** | 8 | 150 | 18.75 | **233.06** |
| **M5 (Fully-enabled)** | 10 | 150 | 15.00 (-20.0%) | **177.06 (-24.0%)** |

This research isolates this exact microarchitectural bottleneck at the RTL level for neural accelerators, determining whether **scale-up** (monolithic arrays) or **scale-out** (distributed smaller nodes) is superior under realistic memory constraints.

## Architecture Overview

<p align="center">
  <img width="500" alt="System Level Architecture" src="https://github.com/user-attachments/assets/b7ee8d5e-19e6-413f-b3f5-351ed32a2556" />
  <br>
  <em>Figure 1: Macroscopic streaming view of cascaded MVU layers.</em>
</p>

The core compute engine is a parameterizable **Matrix-Vector Unit (MVU)** implementing a temporally folded SIMD datapath with per-layer fixed-point integer requantization (Q32 $\to$ INT8) and integrated clipping/activation logic (ReLU / Identity):

<p align="center">
  <img width="500" alt="MVU Microarchitecture" src="https://github.com/user-attachments/assets/bae154e9-44ea-470d-af64-007ab2a9a025" />
  <br>
  <em>Figure 2: Internal microarchitecture of the temporally folded MVU datapath.</em>
</p>

## Purpose / Objectives
- Build a parameterizable SIMD MVU in SystemVerilog:
- Verify functional correctness against a Python golden model with quantized integer behavior.
- Synthesize many hardware geometries (116 configs in 14nm flow) to collect detailed, specific Fmax, area, and power metrics for each of them.
- Project system behavior under memory bandwidth and latency constraints with an Extended Roofline model.
- Compare architectural strategies using throughput and energy-delay tradeoffs.

## Main Conclusions
- Scaling a monolithic datapath (scale-up) increases localized storage/interconnect pressure, reducing frequency scalability and hurting efficiency.
- Under constrained memory systems, distributed scale-out topologies deliver better system-level efficiency. Scale-up topologies take the lead in masking slow memory in edge cases.
- **Winning balanced node:** **PE=8, SIMD=128**.
- **Measured result:** **26.06 GMAC/s @ 254.45 MHz**, **82.60 µW**, **~25,813 µm²**.
<p align="center">
  <img width="500" alt="Extended Roofline Model" src="https://github.com/user-attachments/assets/76600fc8-ba69-411f-82c9-35cffb7544a7" />
  <br>
  <em>Figure 3: Extended Roofline Model demonstrating the Balanced Node (PE=8, SIMD=128) hitting the compute roof under memory constraints.</em>
</p>

- This node gave the best global efficiency balance (throughput vs silicon footprint vs power), while denser monolithic designs increased raw compute ceiling but degraded efficiency due to storage/interconnect overhead.
- In the reported 25 GB/s case, a distributed setup reaches ~104 GMAC/s with ~82% lower power and ~79% lower area than a larger contiguous scale-up alternative (~32 GMAC/s baseline in the paper comparison).
- For this architecture, bandwidth is the dominant memory-side limiter in evaluated scenarios; latency is secondary in most tested operating points.
- SIMD width scaling is not always beneficial to throughput, and will eventually degrade performance and energy efficiency due to datapath congestion.   

### Implementation caveats
To strictly stress-test weight residency limits, this MVU stores neural network parameters in fully unrolled discrete logic registers (flip-flops) instead of hierarchical SRAM/BRAM storage. In dense configurations, this parameter storage dominates the footprint (occupying up to 72.1% of total silicon area), which is the one of the main architectural drivers behind the scale-up failure.

### Methodological boundaries
- Synthesis used a static 70 MHz target for all configurations; reported higher Fmax values reflect post-synthesis slack recovery, not iterative per-configuration max-frequency sweeps.
- Datapath execution is dense (no zero-skipping sparsity control), so all operands are processed.
- Dynamic power estimation used a uniform statistical activity model (toggle_rate = 0.1, static probability 0.5), not workload-specific SAIF/VCD switching traces.

## Research context and infrastructure
This work was developed in Brazilian academic research context (USP) and explicitly used infrastructure from UFRGS: the CADMicro facility (server infrastructure, EDA tool access, and PDK support) that enabled the synthesis and physical characterization runs.

## Repository Structure
- `/docs` — published research artifacts (thesis + conference paper).
- `/analysis` — post-processing and plotting scripts + extracted synthesis dataset.
- `/syn` — Synopsys DC/PT Tcl scripts for synthesis, timing, and power reporting.
- `/` (root) — RTL, testbench, golden model, build orchestration, environment/sweep helpers.

## File-by-File Map (what each file contributes to the research)

### Root
- `README.md` — project overview and reproducibility guide.
- `Golden_Model.py` — quantized Python reference model; generates `weights.txt`, `inputs.txt`, `expected.txt`, and `cfg.txt` used to verify RTL correctness and define experiment vectors.
- `pe_artur.sv` — parameterizable MVU RTL (weight loading FSM + folded SIMD MAC compute + requantization/activation); core hardware under study.
- `tb_pe_artur.sv` — verification and measurement testbench; replays vectors, validates outputs, emulates memory transfer timing (bandwidth/latency), reports cycle/performance metrics, and dumps VCD.
- `Makefile` — central experiment pipeline: vectors → compile/simulate → synthesize (DC) → STA/power (PT) → SAIF flow; manages hardware/software parameterization and result paths.
- `env_synopsys.sh` — module-load script for Synopsys toolchain setup in cluster/lab environments.
- `run_sweep_launch.sh` — launches long sweep jobs in a detached session and records PID/log location.
- `run_sweep_stop.sh` — stops launched sweep process groups with TERM/INT/KILL escalation.
- `requirements.txt` — pinned Python stack (PyTorch/Brevitas/Numpy etc.) for deterministic golden-model generation and analysis scripts.
- `.gitignore` — excludes generated vectors, build artifacts, results, logs, and EDA temporary files.
- `LICENSE` — MIT license.

### `docs/`
- `Full Thesis.pdf` — complete academic treatment: problem framing, architecture, methodology, DSE, roofline/EDP analysis, limitations, and future work.
- `SForum Paper.pdf` — condensed conference version emphasizing scale-up vs scale-out findings and key quantitative outcomes.

### `analysis/`
- `hardware_synthesis.csv` — consolidated dataset extracted from synthesis/timing/power reports; backbone for performance/area/power plots and rankings.
- `extract_hardware_metrics_to_CSV.py` — parses `results/` reports and builds `hardware_synthesis.csv`.
- `simulatedTestbench.py` — software re-simulation of testbench timing equations and roofline-style behavior for selected hardware/memory settings.
- `plotPerf.py` — sweeps and plots Fmax + derived GMAC/s across SIMD/PE/PAD_LANES groupings.
- `plotArea.py` — plots combinational/non-combinational/total area trends across design sweeps.
- `plotPower.py` — plots internal/switching/leakage/total power trends.
- `roofline.py` — extended roofline generator using CSV-extracted Fmax and memory parameters.
- `roofline_sforum.py` — paper-formatted roofline variant tuned for publication figure style.
- `mostEfficient.py` — computes/ranks efficiency metrics (e.g., GMAC/s per power/area) and exports ranked CSV lists.
- `analyze_csv_columns.py` — generic statistical/histogram utility for inspecting any numeric CSV column.

### `syn/`
- `syn/dc/run_dc.tcl` — Design Compiler flow: analyze/elaborate, constraints, compile, and report/netlist generation.
- `syn/pt/run_pt.tcl` — PrimeTime timing + two-pass power/timing analysis (target frequency and inferred Fmax), exporting critical-path and QoR reports.
- `syn/pt/run_power.tcl` — PrimeTime power run using SAIF activity from simulation for hierarchy-level power reporting.

## How to Run (recommended order)

### 1) Python environment + vector generation
```bash
cd /home/runner/work/navigating-the-memory-wall/navigating-the-memory-wall
python3.12 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

Generate vectors through the Makefile pipeline:
```bash
make vectors SIMD=128 CIN=14 KX=3 KY=3 PEQNT=8 NIN=1000 SEED=3
```

### 2) Functional simulation (RTL vs golden model)
```bash
make sim SIMD=128 PE=8 MAX_CHANNELS=14 FCLK_HZ=254e6 MEM_B_GBPS=25 MEM_L_S=1e-9
```

### 3) Synthesis / timing / power (Synopsys)
Load toolchain first:
```bash
source env_synopsys.sh
```

Then run:
```bash
make synth   # Design Compiler netlist + area/timing/power-est reports
make sta     # PrimeTime timing / Fmax derivation
make power   # (THIS IS IN ALPHA!!) PrimeTime power using SAIF (depends on sim -> saif)
```

### 4) Build aggregated dataset and plots
```bash
python analysis/extract_hardware_metrics_to_CSV.py
python analysis/plotPerf.py
python analysis/plotArea.py
python analysis/plotPower.py
python analysis/mostEfficient.py
```

Roofline examples:
```bash
python analysis/roofline.py --simd 128 --maxch 56 --pe 8 --bw 25 --lat 1e-9
python analysis/roofline_sforum.py --simd 128 --maxch 56 --pe 8 --bw 25 --lat 1e-9
```

## Notes
- `run_sweep_launch.sh` expects a `run_sweep.sh` orchestrator script in the repository root.
- Results are written under `results/<hardware_id>/...`, while temporary build artifacts go to `work/`.
- VCD Dump for power analysis was implemented in an early beta stage, but was not used in establishing the power figures in the paper/thesis. 
