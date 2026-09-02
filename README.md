![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# Chrome Chain

A ternary-weight, bit-serial MNIST classifier with a conformally calibrated early exit,
for the Tiny Tapeout shuttle TTSKY26c (KU Leuven TT2026 group 03).

An 8x8, 4-bit image arrives as four bitplanes, MSB first, 8 bits per cycle. A 64-32-10
network with weights in {-1, 0, +1} folds the planes with Horner's rule, so the whole
chip has no multiplier. After each plane a comparator tree yields the current argmax and
its margin; if the margin clears a calibrated threshold the remaining planes are never
run. A 6-byte config blob carries the thresholds and the run options.

- [docs/info.md](docs/info.md): how it works, the host protocol, the output views.
- [src/ckpt_defs.vh](src/ckpt_defs.vh): every width and build constant, in one file.
- [src/cc_top.v](src/cc_top.v): the composition; [src/ckpt_block.v](src/ckpt_block.v) the datapath.
- [test/](test/): the cocotb suite (`cd test && make`, cocotb 2.0.1 on Python 3.12).
- [equiv/](equiv/): the equivalence gate used to check every RTL change against the
  baseline that was green on `main`: differential simulation through the TT pins,
  per-module formal equivalence, synthesis and lint parity.

## Repository layout

```
info.yaml        Tiny Tapeout project metadata; source_files must match test/Makefile
src/             RTL (21 modules + ckpt_defs.vh) and config.json for the hardening flow
docs/info.md     the datasheet
test/            cocotb testbench and tests
equiv/           differential / formal / synthesis / lint gate scripts
```

The GitHub Actions build the GDS with [LibreLane](https://www.zerotoasiccourse.com/terminology/librelane/)
on every push. See the [Tiny Tapeout FAQ](https://tinytapeout.com/faq/) and
[local hardening guide](https://www.tinytapeout.com/guides/local-hardening/).
