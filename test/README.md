# Sample Testbench for a Tiny Tapeout Project

This is a sample testbench for a Tiny Tapeout project. It uses [cocotb](https://docs.cocotb.org/en/stable/) to drive the DUT and check the outputs.
For more information, check the [Tiny Tapeout website](https://tinytapeout.com/hdl/testing/).

## Setting Up

`PROJECT_SOURCES` in the [Makefile](Makefile) lists the 21 RTL files and must stay identical to `source_files` in `../info.yaml`. [tb.v](tb.v) instantiates `tt_um_kul_chromechain`; the tests in [test.py](test.py) drive only the TT pins. cocotb 2.0.1 needs Python 3.12 or 3.13.

## Running Simulations

### RTL Simulation

```sh
make
```

### Gate-Level Simulation

First, harden your project (`make harden` at the repo root), then `make test_gates` there: it copies `runs/wokwi/final/pnl/tt_um_kul_chromechain.pnl.v` to `test/gate_level_netlist.v` and runs:

```sh
make GATES=yes
```

### VCD Waveform Format

By default, waveforms are saved in FST format. To use VCD format instead, edit `tb.v` to use `$dumpfile("tb.vcd");` and run:

```sh
make FST=
```

### Cleaning Build Artifacts

To remove all generated files (`sim_build/`, `__pycache__/`, `results.xml`, `tb.fst`):

```sh
make clean
```

## Viewing Waveforms

With [GTKWave](https://gtkwave.sourceforge.net/):

```sh
gtkwave tb.fst tb.gtkw
```

With [Surfer](https://surfer-project.org/):

```sh
surfer tb.fst
```
