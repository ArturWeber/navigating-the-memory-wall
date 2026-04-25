# navigating-the-memory-wall
Design Space Exploration of bandwidth and latency constraints in SIMD neural accelerators using the Roofline model. Analyzes how memory bottlenecks impact EDP, GOPS, stall cycles, and hardware utilization through automated RTL synthesis with Python and industry-standard EDA tools.

## Quick Start: The Golden Model

Before running the SystemVerilog testbenches in QuestaSim or synthesizing in Design Compiler, you must generate the "Golden Model" data. This Python script calculates the perfect mathematical outputs and generates the raw data files (`input.txt`, `weights_int8.txt`, `output.txt`) that the hardware simulator will read.

### Prerequisites
* **Python 3.12** (Strictly required to ensure compatibility with pre-compiled PyTorch and Brevitas binaries).

### Installation & Setup

**1. Create a stable virtual environment** Avoid installing dependencies globally. Create an isolated environment using Python 3.12:
```bash
python3.12 -m venv venv
```

**2. Activate the environment** *On macOS and Linux:*
```bash
source venv/bin/activate
```
*On Windows:*
```bash
.\venv\Scripts\activate
```

**3. Install the required dependencies** Install the exact, verified snapshot of the machine learning libraries to prevent version conflicts:
```bash
pip install -r requirements.txt
```

**4. Generate the Hardware Test Data** Run the verification script to generate the quantization configuration and I/O text files:
```bash
python scriptest_pe_fc.py
```