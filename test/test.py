# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

# uo_out (dft_sel = 2'b00, "view 0") bit layout -- see tt_um_kul_chromechain.v:11-19
ERR_ANY  = 0x80
BUSY     = 0x40
LD_READY = 0x20
DONE     = 0x10
ANSWER   = 0x0F

# uio_in control bits -- tt_um_kul_chromechain.v:37-42
LD_EN    = 1 << 0
CFG_MODE = 1 << 2
CFG_STB  = 1 << 3
START    = 1 << 4

# Reset-default config blob (T1=1023 disarmed, T2=8, T3=12, ckpt_en=3'b110,
# en_skip=0, page_sel=0, inv_plane=0, n_cap=4=PLANES, en_vstrobe=0), split into
# CFG_WORDS=6 host bytes. Writing the power-on default back is the simplest
# blob that is guaranteed valid: it reproduces exactly the un-loaded reset
# state, so nothing in config_latch/checkpoint_ctrl can reject it.
RESET_BLOB = [0xFF, 0x23, 0xC0, 0x80, 0x01, 0x02]

PLANES = 4
BEATS_PER_PLANE = 8
TOTAL_BEATS = PLANES * BEATS_PER_PLANE  # 32


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    clock = Clock(dut.clk, 10, unit="us")
    cocotb.start_soon(clock.start())

    dut._log.info("Reset")
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)

    dut._log.info("Load config blob")
    for word in RESET_BLOB:
        dut.ui_in.value = word
        dut.uio_in.value = CFG_MODE | CFG_STB
        await ClockCycles(dut.clk, 1)
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 1)  # let cfg_blob_done / blob_loaded register

    dut._log.info("Pulse start")
    dut.uio_in.value = START
    await ClockCycles(dut.clk, 1)
    dut.uio_in.value = 0

    # Wait for busy, then one extra cycle: ld_en must not be asserted on the
    # img_start cycle (the same cycle busy first reads 1) or bitplane_buffer
    # raises frame_err.
    for _ in range(20):
        await ClockCycles(dut.clk, 1)
        if int(dut.uo_out.value) & BUSY:
            break
    else:
        assert False, "design never went busy after start"
    await ClockCycles(dut.clk, 1)

    dut._log.info("Feed a blank (all-zero) image, 32 beats, gated by ld_ready")
    beats_sent = 0
    guard = 0
    while beats_sent < TOTAL_BEATS:
        # ld_en must be low and settled for a full cycle before we resample
        # ld_ready -- pulsing it back-to-back races the buffer's internal
        # fill counter and trips a false frame_err overrun.
        dut.uio_in.value = 0
        await ClockCycles(dut.clk, 1)
        status = int(dut.uo_out.value)
        assert not (status & ERR_ANY), "error flag set while feeding image"
        if status & LD_READY:
            dut.ui_in.value = 0x00
            dut.uio_in.value = LD_EN
            await ClockCycles(dut.clk, 1)
            status = int(dut.uo_out.value)
            assert not (status & ERR_ANY), "error flag set right after ld_en pulse"
            beats_sent += 1
        guard += 1
        assert guard < 4000, "timed out waiting for ld_ready while loading image"
    dut.uio_in.value = 0

    dut._log.info("Wait for done")
    for _ in range(2000):
        await ClockCycles(dut.clk, 1)
        status = int(dut.uo_out.value)
        assert not (status & ERR_ANY), "error flag set while classifying"
        if status & DONE:
            break
    else:
        assert False, "timed out waiting for done"

    status = int(dut.uo_out.value)
    answer = status & ANSWER
    dut._log.info(f"done: answer={answer}, status=0x{int(status):02x}")
    assert not (status & ERR_ANY), "error flag set at completion"
    assert not (status & BUSY), "busy still set at completion"
    assert 0 <= answer <= 9, f"answer {answer} out of expected digit range"
