##############################################################
#            Projeto de Formatura I - SCC0670                #
#                                                            #
#      By: Artur Brenner Weber                               #
#      Last Update: 26/5/2026                                #
#                                                            #
#  Written based on a Jupyter Notebook originally by         #
#  Eduardo Sperle Honorato. This is a golden model for       #
#  simulating the ideal hardware behavior.                   #
##############################################################

import argparse, math, random, os
import numpy as np
import torch
import torch.nn as nn
import brevitas.nn as qnn
from brevitas.quant import Int8ActPerTensorFixedPoint

PRECISION_N = 32
USE_RELU = True  # True for ReLU, False for Identity

def seed_all(seed: int):
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False

class GoldenLinear(nn.Module):
    def __init__(self, dot_len: int, pe_qnt: int, bit_width: int):
        super().__init__()
        self.quant_inp = qnn.QuantIdentity(bit_width=bit_width, return_quant_tensor=True)
        self.fc = qnn.QuantLinear(
            dot_len, pe_qnt,
            bias=False,
            weight_bit_width=bit_width,
            output_quant=Int8ActPerTensorFixedPoint,
            return_quant_tensor=True
        )

    def forward(self, x):
        x = self.quant_inp(x)
        x = self.fc(x)
        return x

def clip_int8(x: torch.Tensor) -> torch.Tensor:
    return torch.clamp(x, -128, 127).to(torch.int8)

def golden_hw_int8(x_int8, w_int8, Mint, use_relu=True):
    x = x_int8.to(torch.int32)
    w = w_int8.to(torch.int32)
    acc = x @ w.t()
    acc64 = acc.to(torch.int64)
    rounding = 1 << (PRECISION_N - 1)
    y = (acc64 * int(Mint) + rounding) >> PRECISION_N
    if use_relu:
        y = torch.clamp(y, 0, 127)
    else:
        y = torch.clamp(y, -128, 127)
    return y.to(torch.int8)

def pack_to_folds(vec_int8: torch.Tensor, simd: int, fold_qnt: int):
    D = vec_int8.numel()
    total = simd * fold_qnt
    if D > total:
        raise ValueError(f"D={D} > simd*fold_qnt={total}")
    padded = torch.zeros(total, dtype=torch.int8)
    padded[:D] = vec_int8
    return padded.view(fold_qnt, simd)  # (F, SIMD)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--bit_width", type=int, default=8)
    ap.add_argument("--cin", type=int, default=16)           # input channels
    ap.add_argument("--kx", type=int, default=3)
    ap.add_argument("--ky", type=int, default=3)
    ap.add_argument("--pe_qnt", type=int, default=16)
    ap.add_argument("--simd", type=int, default=64)
    ap.add_argument("--n_inputs", type=int, default=1000)
    ap.add_argument("--out_dir", default="vectors")
    args = ap.parse_args()

    seed_all(args.seed)

    dot_len = args.cin * args.kx * args.ky
    fold_qnt = math.ceil(dot_len / args.simd)

    model = GoldenLinear(dot_len, args.pe_qnt, args.bit_width).eval()

    # Random FP input -> quantized int8 input
    x_fp = torch.randn(args.n_inputs, dot_len)

    with torch.no_grad():
        q_in = model.quant_inp(x_fp)
        s_in = float(model.quant_inp.act_quant.scale().item())
        x_int8 = clip_int8(torch.round(q_in / s_in))

        w_int8 = clip_int8(model.fc.quant_weight().int())
        w_scale = model.fc.weight_quant.scale().detach().cpu()
        s_out = float(model.fc.output_quant.scale().item())

    # Enforce per-tensor weight scale (one scale per layer)
    if w_scale.numel() != 1:
        raise RuntimeError(
            f"Per-channel weight scale detected (numel={w_scale.numel()}). "
            "RTL uses one scale per layer; configure Brevitas for per-tensor weight scale."
        )
    s_w = float(w_scale.item())

    M = (s_in * s_w) / s_out
    Mint = int(round(M * (1 << PRECISION_N)))

    # Golden int8 matching RTL integer requant
    y_hw = golden_hw_int8(x_int8, w_int8, Mint, use_relu=USE_RELU)

    os.makedirs(args.out_dir, exist_ok=True)
    weights_path = os.path.join(args.out_dir, "weights.txt")
    inputs_path  = os.path.join(args.out_dir, "inputs.txt")
    exp_path     = os.path.join(args.out_dir, "expected.txt")
    cfg_path     = os.path.join(args.out_dir, "cfg.txt")

    with open(cfg_path, "w") as f:
        f.write(f"cin {args.cin}\n")
        f.write(f"kx {args.kx}\n")
        f.write(f"ky {args.ky}\n")
        f.write(f"dot_len {dot_len}\n")
        f.write(f"simd {args.simd}\n")
        f.write(f"fold_qnt {fold_qnt}\n")
        f.write(f"pe_qnt {args.pe_qnt}\n")
        f.write(f"Mint {Mint}\n")
        f.write(f"act_fun {1 if USE_RELU else 0}\n")

    # weights.txt format (ONE Mint per layer):
    # for p in 0..pe_qnt-1:
    #   for fold in 0..fold_qnt-1: SIMD ints
    # then final line: Mint
    with open(weights_path, "w") as f:
        for p in range(args.pe_qnt):
            folds = pack_to_folds(w_int8[p], args.simd, fold_qnt)
            for fold in range(fold_qnt):
                f.write(" ".join(str(int(v)) for v in folds[fold].tolist()) + "\n")
        f.write(str(int(Mint)) + "\n")

    # inputs.txt: each input is fold_qnt lines of SIMD ints
    with open(inputs_path, "w") as f:
        for b in range(args.n_inputs):
            folds = pack_to_folds(x_int8[b], args.simd, fold_qnt)
            for fold in range(fold_qnt):
                f.write(" ".join(str(int(v)) for v in folds[fold].tolist()) + "\n")

    # expected.txt: 1 line per input, pe_qnt ints
    with open(exp_path, "w") as f:
        for b in range(args.n_inputs):
            f.write(" ".join(str(int(v)) for v in y_hw[b].tolist()) + "\n")

    print("Generated in:", args.out_dir)
    print(f"  dot_len={dot_len}, fold_qnt={fold_qnt}, pe_qnt={args.pe_qnt}, simd={args.simd}")
    print(f"  scales: s_in={s_in}, s_w={s_w}, s_out={s_out}")
    print(f"  M={M}, Mint(Q32)={Mint}")
    print(f"  USE_RELU={USE_RELU}")

if __name__ == "__main__":
    main()