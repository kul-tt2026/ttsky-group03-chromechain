# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
#
# Chrome Chain smoke test.
#
# SCOPE, stated so nobody mistakes this for the verification. The real gate is
# `python3 l2_synthesis/verify.py` in the design repo: 65 checks, including a
# 10,000-image end-to-end replay of both plane orderings and both modes against a
# cycle-accurate model, reproducing every aggregate exactly. That needs the MNIST-derived
# vectors, which are megabytes and do not belong in a Tiny Tapeout submission.
#
# What this file does is what the TT flow actually needs: prove the wrapper elaborates,
# resets cleanly, honours the K12 gate, and accepts a config blob. Those are the four
# things that would make the returned silicon un-debuggable if they were wrong, and they
# are cheap to check here.
#
# Pin mapping is tt_um_kul_chromechain.v's:
#   ui_in[7:0]   shared data bus -- pixel beats and config words
#   uio_in[0] ld_en   [1] ld_vstrobe  [2] cfg_mode  [3] cfg_stb  [4] start  [6:5] dft_sel
#   uo_out view 0 (dft_sel=0): {err_any, busy, ld_ready, done, answer[3:0]}
#   uo_out view 2 (dft_sel=2): {blob_loaded, ld_done, ld_idx[1:0], 1'b0, exit_k[2:0]}

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

CFG_WORDS = 6  # v1.1 blob; v1 is 16. ckpt_defs.vh "WHICH BUILD IS THIS" is the authority.

LD_EN, LD_VSTB, CFG_MODE, CFG_STB, START = 0, 1, 2, 3, 4
DFT_SHIFT = 5


def ctrl(**bits):
    """Build uio_in from named control bits, with dft_sel in [6:5]."""
    v = bits.pop("dft", 0) << DFT_SHIFT
    for name, pos in (("ld_en", LD_EN), ("ld_vstb", LD_VSTB), ("cfg_mode", CFG_MODE),
                      ("cfg_stb", CFG_STB), ("start", START)):
        if bits.get(name):
            v |= 1 << pos
    return v


@cocotb.test()
async def test_reset_and_k12(dut):
    """After reset the chip is idle, and `start` before a blob is loaded does nothing."""
    dut._log.info("Chrome Chain -- reset and K12 gate")
    cocotb.start_soon(Clock(dut.clk, 10, unit="us").start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    uo = int(dut.uo_out.value)
    assert (uo >> 7) & 1 == 0, f"a sticky alarm is set straight out of reset (uo_out={uo:#04x})"
    assert (uo >> 6) & 1 == 0, f"busy is high with no image started (uo_out={uo:#04x})"
    assert (uo >> 4) & 1 == 0, f"done is high before anything ran (uo_out={uo:#04x})"

    # K12: start must be ignored until the blob has been loaded. tb_cc_top proves the
    # same property in the design repo; this is the version that runs in TT's CI.
    dut.uio_in.value = ctrl(start=1)
    await ClockCycles(dut.clk, 1)
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 8)

    uo = int(dut.uo_out.value)
    assert (uo >> 6) & 1 == 0, "K12 violated: start before blob_loaded began an image"
    assert (uo >> 7) & 1 == 0, "an alarm fired on an ignored start"


@cocotb.test()
async def test_config_load(dut):
    """The blob loader accepts CFG_WORDS bytes and raises blob_loaded, with no alarm."""
    dut._log.info("Chrome Chain -- config blob load")
    cocotb.start_soon(Clock(dut.clk, 10, unit="us").start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    # blob_loaded lives in view 2, bit 7.
    dut.uio_in.value = ctrl(dft=2)
    await ClockCycles(dut.clk, 1)
    assert (int(dut.uo_out.value) >> 7) & 1 == 0, "blob_loaded high before any load"

    # One strobe per word; the loader owns the address, the host only counts.
    for word in range(CFG_WORDS):
        dut.ui_in.value = word          # content is irrelevant to this test
        dut.uio_in.value = ctrl(cfg_mode=1, cfg_stb=1)
        await ClockCycles(dut.clk, 1)
        dut.uio_in.value = ctrl(cfg_mode=1)
        await ClockCycles(dut.clk, 1)

    dut.uio_in.value = ctrl(dft=2)
    await ClockCycles(dut.clk, 2)
    uo = int(dut.uo_out.value)
    assert (uo >> 7) & 1 == 1, f"blob_loaded low after {CFG_WORDS} words (uo_out={uo:#04x})"

    dut.uio_in.value = ctrl(dft=3)      # view 3 = the five sticky alarms, individually
    await ClockCycles(dut.clk, 1)
    alarms = int(dut.uo_out.value) & 0x1F
    assert alarms == 0, f"alarms set after a well-formed blob load: {alarms:#04x}"
