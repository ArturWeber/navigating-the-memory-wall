#!/bin/bash
source env_synopsys.sh # Ensure your tools are in the path
for s in 2 8 32 256; do
    for p in 5 10 20 30; do
        for c in 5 10 20 30; do
            make sta SIMD=$s PE=$p MAX_CHANNELS=$c FCLK_HZ=2e9
        done
    done
done
