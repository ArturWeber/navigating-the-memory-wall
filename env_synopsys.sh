module purge
module use /tools/modulefiles

module load synopsys/vcs/W-2024.09-SP2-3
module load synopsys/designcompiler/W-2024.09-SP5-4
module load synopsys/primetime/W-2024.09-SP5-2
module load synopsys/ppower/W-2024.09-SP5-2
module load synopsys/lc/W-2024-SP5-3

which vcs || true
which dc_shell || true
which pt_shell || true
which primepower || true
which lc_shell || true