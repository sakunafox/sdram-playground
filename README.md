# sdram-playground

One SDRAM lesson, two bodies:

- `index.html` - visual toy. You hand-drive the controller with buttons,
  watch banks open and close, watch capacitors leak in real time.
  Live at https://sakunafox.github.io/sdram-playground/
- `sim/` - the same world in Verilog. A behavioral SDRAM model that
  yells at protocol violations, plus a testbench with a command task
  library and four demo scenes.

Both share the same geometry (4 banks x 8 rows x 8 cols, one byte per
cell) and the same timing (tRCD=2, tRP=2, tRAS=4, CL=2), so what you
learn by clicking transfers 1:1 to what you simulate.

## sim quickstart

```
cd sim
make        # iverilog + vvp, prints the four scenes and a verdict
make wave   # dumps tb.vcd, opens gtkwave
```

Scenes:

1. polite read/write - ACT, wait tRCD, WRITE, READ back, check, PRE
2. crime scene - READ with no open row, READ before tRCD
3. tRAS punishment - PRE too early corrupts the row
4. leakage - unrefreshed rows decay to x; a proper refresh sweep saves them

## write your own controller

The model (`sim/sdram_model.v`) is the referee. Replace the testbench's
hand-issued commands with your own FSM: drive cs_n/ras_n/cas_n/we_n/ba/addr
from a module, keep the model on the other side of the wires, and let it
yell at you until it stops yelling. That silence is your controller working.

Command encoding on {ras_n, cas_n, we_n} with cs_n low, sampled at
posedge clk:

| ras cas we | command      |
|------------|--------------|
| 0 1 1      | ACTIVATE     |
| 1 0 1      | READ         |
| 1 0 0      | WRITE        |
| 0 1 0      | PRECHARGE    |
| 0 0 1      | AUTO REFRESH |
| 0 0 0      | LOAD MODE REG|
| 1 1 0      | BURST STOP   |
| 1 1 1      | NOP          |
