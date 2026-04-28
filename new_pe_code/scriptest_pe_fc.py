import torch
import torch.nn as nn
import brevitas.nn as qnn
from brevitas.quant import Int8ActPerTensorFixedPoint

from math import ceil

# ============================================
# CONFIG
# ============================================
BRAM_DATA_WIDTH = 128
BIT_WIDTH = 8
BIT_USED = int(BRAM_DATA_WIDTH/BIT_WIDTH)
PRECISION_N = 32
INPUT_CHANNEL=64
OUTPUT_CHANNEL=8

# ============================================
# MODELO
# ============================================
class TinyCNN(nn.Module):
    def __init__(self):
        super().__init__()
        self.quant_inp = qnn.QuantIdentity(
            bit_width=BIT_WIDTH,
            return_quant_tensor=True
        )
        self.linear = qnn.QuantLinear(
            INPUT_CHANNEL, OUTPUT_CHANNEL,
            bias=False,
            weight_bit_width=BIT_WIDTH,
            output_quant=Int8ActPerTensorFixedPoint,
            return_quant_tensor=True
        )
    def forward(self, x):
        x = self.quant_inp(x)
        x = self.linear(x)
        return x

model = TinyCNN().eval()

# ============================================
# INPUT (N_INPUTS, INPUT_CHANNEL)
# ============================================
input_fp = torch.randn(2,INPUT_CHANNEL)

with torch.no_grad():
    q_input = model.quant_inp(input_fp)

input_scale = model.quant_inp.act_quant.scale().item()

input_int = torch.round(
    q_input / input_scale
).clamp(-128,127).to(torch.int8)

# ============================================
# PESOS
# ============================================
weight_int = model.linear.quant_weight().int()
weight_scale = model.linear.weight_quant.scale().detach()

# ============================================
# BIAS (INT32 correto)
# ============================================
# bias_fp = model.linear.bias.detach()

if weight_scale.numel() == 1:
    acc_scale = input_scale * weight_scale.item()
else:
    acc_scale = input_scale * weight_scale

# bias_int = torch.round(
#     bias_fp / acc_scale
# ).to(torch.int32)

# ============================================
# OUTPUT SCALE
# ============================================
output_scale = model.linear.output_quant.scale().item()

# ============================================
# M_int (Q32)
# ============================================
M_int = []
for f in range(weight_int.shape[0]):
    if weight_scale.numel() == 1:
        w_scale = weight_scale.item()
    else:
        w_scale = weight_scale[f].item()
    M = (input_scale * w_scale) / output_scale
    Mint = int(round(M * (1 << PRECISION_N)))
    M_int.append(Mint)

# ============================================
# OUTPUT REAL INT8
# ============================================
with torch.no_grad():
    out = model(input_fp)

out_int8 = torch.round(
    out / output_scale
).clamp(-128,127).to(torch.int8)

# ============================================
# 1) INPUT (8 valores por linha)
# ============================================
with open("input.txt", "w") as f:

    B, C = input_int.shape
    for i in range(B):
        count=0
        for c in range(C):
            f.write(str(int(input_int[i,c]))+" ")
            count+=1
            if (count%BIT_USED==0 and count!=0):
                f.write("\n")
        if (count%BIT_USED!=0):
            while (count%BIT_USED!=0):
                f.write("0 ")
                count+=1
            f.write("\n")
            
# ============================================
# 2) WEIGHTS (8 filtros alinhados)
# ============================================
with open("weights_int8.txt", "w") as f:

    out_ch, in_ch, = weight_int.shape
    for oc in range(8):
        out_put_channel_counters=0
        while out_put_channel_counters<out_ch:
            flat = weight_int[oc+out_put_channel_counters].reshape(-1).tolist()
            out_put_channel_counters+=8
            count=0
            for i in range(0, len(flat), BIT_USED):
                count+=1
                chunk = flat[i:i+BIT_USED]
                f.write(" ".join(str(x) for x in chunk) + "\n")
            while count<3:
                count+=1
                f.write("0 "*BIT_USED+"\n")

# ============================================
# 3) BIAS
# ============================================
# with open("bias.txt", "w") as f:
#     dict_bias_pos={}
#     count=0
#     for b in bias_int:
#         dict_bias_pos[count]=b
#         count+=1
#     for pos in range(0,8,2):
#         out_put_channel_counters=0
#         while out_put_channel_counters<ceil(OUTPUT_CHANNEL):
#             f.write(f"{int(dict_bias_pos[pos+out_put_channel_counters])} ")
#             f.write(f"{int(dict_bias_pos[pos+1+out_put_channel_counters])} ")
#             out_put_channel_counters+=8
#         f.write(f"\n")

# ============================================
# 4) M_int
# ============================================
with open("M_int.txt", "w") as f:
    for m in M_int:
        f.write(f"{m}\n")

# ============================================
# 5) OUTPUT (8 canais por linha)
# ============================================
with open("output.txt", "w") as f:

    for out_values in out_int8.tolist():
        C=len(out_values)
        line = []
        count=0
        for c in range(C):
            line.append(int(out_values[c]))
            count+=1
            if (count%8==0):
                f.write(" ".join(map(str,line)) + "\n")
                line=[]

# ============================================
# 6) CONFIGURAÇÃO
# ============================================
with open("config.txt", "w") as f:
        f.write("cfg_c  = "+str(INPUT_CHANNEL)+";\n")
        f.write("cfg_ky = "+str(2)+";\n")
        f.write("cfg_kx = "+str(1)+";\n")
        f.write("cfg_w  = "+str(int(INPUT_CHANNEL/BIT_USED))+  ";\n")
        f.write("cfg_mem_channel_distance_1= "+ str(1) +";\n")
        f.write("cfg_mem_channel_distance_2= "+ str(2) +";\n")
        f.write("cfg_op_type = " + str(1) + ";\n")
        f.write("cfg_conv_D = " + str(0) + ";\n")
        f.write("cfg_depth_conv = " + str(0) + ";\n")
        f.write("cfg_w_wg = "+ str(max(3, int(INPUT_CHANNEL/BIT_USED)))+ ";\n")
        f.write("cfg_max_out = "+ str(OUTPUT_CHANNEL)+ ";\n")
        f.write("cfg_w_wg_max_out = "+ str(max(3, int(INPUT_CHANNEL/BIT_USED))*ceil(OUTPUT_CHANNEL/8)) +";\n")
        f.write("cfg_w_bias_max_out = "+ str(ceil(OUTPUT_CHANNEL/8)) +";\n")
        f.write("cfg_mem_shifter = "+ str(1)+ ";\n")
        f.write("m_int = "+ str(M_int[0])+ ";")

print("Arquivos gerados corretamente!")
