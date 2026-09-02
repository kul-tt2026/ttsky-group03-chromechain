# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
#
# Chrome Chain cocotb suite.
#
# What it covers: the wrapper elaborates and resets cleanly, START is ignored until a
# blob is loaded, a blob loads with no alarm, an aborted load can be restarted, and
# real images run end to end through the TT pins with the answer, the exit index and a
# cycle bound checked against values measured on the RTL that was green on main.
# There are no golden vectors in this repository; the end-to-end expectations pin the
# shipped behaviour, they do not prove it correct against a model.
#
# Pin mapping is tt_um_kul_chromechain.v's:
#   ui_in[7:0]   shared data bus -- pixel beats and config words
#   uio_in[0] ld_en   [1] ld_vstrobe  [2] cfg_mode  [3] cfg_stb  [4] start  [6:5] dft_sel
#   uo_out view 0 (dft_sel=0): {err_any, busy, ld_ready, done, answer[3:0]}
#   uo_out view 2 (dft_sel=2): {blob_loaded, ld_done, ld_idx[1:0], scan_busy, exit_k[2:0]}
#   uo_out view 3 (dft_sel=3): {0, 0, 0, cap_err, blob_err, frame_err, scan_err, sched_err}
#
# Host protocol (the RTL's): load the blob, pulse START, leave one idle cycle, then feed
# the planes MSB-first, 8 beats each, one beat per cycle only while LD_READY is high.
# DONE pulses for one cycle with the answer on uo_out[3:0]; the answer is then held.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

LD_EN, LD_VSTB, CFG_MODE, CFG_STB, START = 0, 1, 2, 3, 4
DFT_SHIFT = 5

# Blob layout, ckpt_defs.vh CFG_*_LSB: T1[9:0] T2[19:10] T3[29:20] en[32:30] skip[33]
# page[34] inv[38:35] ncap[41:39] vst[42]. Defaults: T1 1023 (disarmed), T2 8, T3 12.
def mkblob(t1=1023, t2=8, t3=12, en=0b110, skip=0, page=0, inv=0, ncap=4, vst=0):
    v = (t1 & 0x3FF) | ((t2 & 0x3FF) << 10) | ((t3 & 0x3FF) << 20) | ((en & 7) << 30)
    v |= (skip & 1) << 33 | (page & 1) << 34 | (inv & 0xF) << 35 | (ncap & 7) << 39 | (vst & 1) << 42
    return [(v >> (8 * i)) & 0xFF for i in range(6)]

# Images as four 64-bit planes, MSB plane first, bit n = pixel n (row-major 8x8).
# IMG_EARLY: decided at checkpoint 2, answer 5.  IMG_FULL: runs all four planes, answer 5.
IMG_EARLY = (0xd1d788a381de9003, 0xdb5f10b68d3b801a, 0x9c8b8839f91d02f2, 0xf6cec2ede4afc2c9)
IMG_FULL  = (0xF0F00F0FAA551234, 0x0123456789ABCDEF, 0xFFFF0000FFFF0000, 0x8001400220041008)


def ctrl(**bits):
    v = bits.pop("dft", 0) << DFT_SHIFT
    for name, pos in (("ld_en", LD_EN), ("ld_vstb", LD_VSTB), ("cfg_mode", CFG_MODE),
                      ("cfg_stb", CFG_STB), ("start", START)):
        if bits.get(name):
            v |= 1 << pos
    return v


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="us").start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)


async def load_blob(dut, words):
    """One strobe per word, cfg_mode held high for the whole load."""
    for w in words:
        dut.ui_in.value = w
        dut.uio_in.value = ctrl(cfg_mode=1, cfg_stb=1)
        await FallingEdge(dut.clk)
        dut.uio_in.value = ctrl(cfg_mode=1)
        await FallingEdge(dut.clk)
    dut.uio_in.value = 0
    dut.ui_in.value = 0
    await FallingEdge(dut.clk)


def view(dut):
    return int(dut.uo_out.value)


async def feed_plane(dut, bits, st):
    """8 beats, LSB byte first, one per cycle while LD_READY (view 0, uo_out[5]) is
    high. Stops (returns False) if DONE has already been seen: after an early exit the
    FSM swaps no more planes, so LD_READY never returns and a beat would be an overrun."""
    for i in range(8):
        waited = 0
        while not ((view(dut) >> 5) & 1):
            if st["done"] is not None or waited > 400:
                return False
            await FallingEdge(dut.clk)
            waited += 1
        dut.ui_in.value = (bits >> (8 * i)) & 0xFF
        dut.uio_in.value = ctrl(ld_en=1)
        await FallingEdge(dut.clk)
        dut.uio_in.value = 0
        dut.ui_in.value = 0
    return True


async def run_image(dut, planes, maxwait=3000):
    """START, one idle cycle, the planes, then wait for DONE. DONE is a one-cycle pulse
    that can land while the host is still feeding (an exit at checkpoint 2 resolves
    about when plane 4's last beat goes in), so a watcher samples view 0 every cycle.
    Returns (answer, cycles from the START edge to DONE)."""
    st = {"done": None, "answer": None, "cyc": 0, "stop": False}

    async def watcher():
        while not st["stop"]:
            await FallingEdge(dut.clk)
            st["cyc"] += 1
            v = view(dut)
            if st["done"] is None and (v >> 4) & 1:
                st["done"], st["answer"] = st["cyc"], v & 0xF

    dut.uio_in.value = ctrl(start=1)          # dft_sel = 0 throughout the image
    cocotb.start_soon(watcher())
    await FallingEdge(dut.clk)
    dut.uio_in.value = 0
    await FallingEdge(dut.clk)                # the idle cycle the host owes at img_start
    for p in planes:
        if st["done"] is not None or not await feed_plane(dut, p, st):
            break
    while st["done"] is None and st["cyc"] < maxwait:
        await FallingEdge(dut.clk)
    st["stop"] = True
    if st["done"] is None:
        raise AssertionError(f"DONE never pulsed within {maxwait} cycles")
    return st["answer"], st["done"]


async def read_exit_k_and_alarms(dut):
    dut.uio_in.value = ctrl(dft=2)
    await FallingEdge(dut.clk)
    exit_k = view(dut) & 7
    dut.uio_in.value = ctrl(dft=3)
    await FallingEdge(dut.clk)
    alarms = view(dut) & 0x1F
    dut.uio_in.value = ctrl(dft=0)
    await FallingEdge(dut.clk)
    return exit_k, alarms


CFG_WORDS = 6  # blob length in words; ckpt_defs.vh CFG_WORDS


@cocotb.test()
async def test_reset_and_k12(dut):
    """After reset the chip is idle, and `start` before a blob is loaded does nothing."""
    dut._log.info("Chrome Chain -- reset and K12 gate")
    await reset(dut)

    uo = view(dut)
    assert (uo >> 7) & 1 == 0, f"a sticky alarm is set straight out of reset (uo_out={uo:#04x})"
    assert (uo >> 6) & 1 == 0, f"busy is high with no image started (uo_out={uo:#04x})"
    assert (uo >> 4) & 1 == 0, f"done is high before anything ran (uo_out={uo:#04x})"
    assert (uo >> 5) & 1 == 1, f"LD_READY should be high with an empty fill buffer (uo_out={uo:#04x})"

    # K12: start must be ignored until the blob has been loaded.
    dut.uio_in.value = ctrl(start=1)
    await FallingEdge(dut.clk)
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 8)
    await FallingEdge(dut.clk)

    uo = view(dut)
    assert (uo >> 6) & 1 == 0, "K12 violated: start before blob_loaded began an image"
    assert (uo >> 7) & 1 == 0, "an alarm fired on an ignored start"


@cocotb.test()
async def test_config_load(dut):
    """The blob loader accepts CFG_WORDS bytes and raises blob_loaded, with no alarm."""
    dut._log.info("Chrome Chain -- config blob load")
    await reset(dut)

    # blob_loaded lives in view 2, bit 7.
    dut.uio_in.value = ctrl(dft=2)
    await FallingEdge(dut.clk)
    assert (view(dut) >> 7) & 1 == 0, "blob_loaded high before any load"

    # One strobe per word; the loader owns the address, the host only counts.
    await load_blob(dut, list(range(CFG_WORDS)))   # content is irrelevant to this test

    dut.uio_in.value = ctrl(dft=2)
    await FallingEdge(dut.clk)
    uo = view(dut)
    assert (uo >> 7) & 1 == 1, f"blob_loaded low after {CFG_WORDS} words (uo_out={uo:#04x})"

    dut.uio_in.value = ctrl(dft=3)      # view 3 = the five sticky alarms, individually
    await FallingEdge(dut.clk)
    alarms = view(dut) & 0x1F
    assert alarms == 0, f"alarms set after a well-formed blob load: {alarms:#04x}"


@cocotb.test()
async def test_e2e_early_exit(dut):
    """A fixed image decided at checkpoint 2: answer 5, exit_k 2, well under a full run."""
    await reset(dut)
    await load_blob(dut, mkblob())
    answer, cycles = await run_image(dut, IMG_EARLY)
    exit_k, alarms = await read_exit_k_and_alarms(dut)
    dut._log.info(f"early-exit image: answer={answer} exit_k={exit_k} cycles={cycles} alarms={alarms:05b}")
    assert answer == 5, f"answer {answer}, expected 5"
    assert exit_k == 2, f"exit_k {exit_k}, expected 2 (checkpoint 2)"
    assert alarms == 0, f"alarms set: {alarms:05b}"
    # Measured 149 on the baseline: START..DONE with 2 planes fed + GAMMA. A full run
    # is 277. The bound proves the exit actually saved the last two planes.
    assert 120 <= cycles <= 180, f"{cycles} cycles START..DONE, expected ~149"
    # BUSY must have fallen with DONE.
    await FallingEdge(dut.clk)
    assert (view(dut) >> 6) & 1 == 0, "BUSY still high after DONE"


@cocotb.test()
async def test_e2e_full_run(dut):
    """A fixed image that clears no checkpoint: all four planes run, exit_k 0, answer 5."""
    await reset(dut)
    await load_blob(dut, mkblob())
    answer, cycles = await run_image(dut, IMG_FULL)
    exit_k, alarms = await read_exit_k_and_alarms(dut)
    dut._log.info(f"full-run image: answer={answer} exit_k={exit_k} cycles={cycles} alarms={alarms:05b}")
    assert answer == 5, f"answer {answer}, expected 5"
    assert exit_k == 0, f"exit_k {exit_k}, expected 0 (ran to the final plane)"
    assert alarms == 0, f"alarms set: {alarms:05b}"
    assert 250 <= cycles <= 300, f"{cycles} cycles START..DONE, expected ~277 (4 x 64 + GAMMA)"


@cocotb.test()
async def test_e2e_zero_skip(dut):
    """Same full-run image with zero-skip enabled: same answer, far fewer cycles."""
    await reset(dut)
    await load_blob(dut, mkblob(skip=1))
    answer, cycles = await run_image(dut, IMG_FULL)
    exit_k, alarms = await read_exit_k_and_alarms(dut)
    dut._log.info(f"zero-skip image: answer={answer} exit_k={exit_k} cycles={cycles} alarms={alarms:05b}")
    assert answer == 5, f"answer {answer}, expected 5"
    assert exit_k == 0
    assert alarms == 0, f"alarms set: {alarms:05b}"
    assert 100 <= cycles <= 150, f"{cycles} cycles START..DONE, expected ~125"


@cocotb.test()
async def test_config_restart_after_abort(dut):
    """blob_loader.v cnt_eff: an aborted load restarted with cfg_mode and cfg_stb
    raised in the SAME cycle must land word 0 at address 0 and count it.
    Without cnt_eff the restart word lands at the old count, the load overruns
    (blob_err) and the thresholds end up in the wrong words."""
    await reset(dut)
    # Abort after two words: drop cfg_mode without finishing.
    for w in mkblob()[:2]:
        dut.ui_in.value = w
        dut.uio_in.value = ctrl(cfg_mode=1, cfg_stb=1)
        await FallingEdge(dut.clk)
        dut.uio_in.value = ctrl(cfg_mode=1)
        await FallingEdge(dut.clk)
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)
    # Restart: cfg_mode rises in the same cycle as the first strobe.
    await load_blob(dut, mkblob())
    dut.uio_in.value = ctrl(dft=2)
    await FallingEdge(dut.clk)
    assert (view(dut) >> 7) & 1 == 1, "blob_loaded low after the restarted load"
    dut.uio_in.value = ctrl(dft=3)
    await FallingEdge(dut.clk)
    alarms = view(dut) & 0x1F
    assert alarms == 0, f"alarms after restarted load: {alarms:05b} (bit 3 = blob_err)"
    # And the config that landed is the right one: the early-exit image still exits at 2.
    dut.uio_in.value = 0
    await FallingEdge(dut.clk)
    answer, cycles = await run_image(dut, IMG_EARLY)
    exit_k, alarms = await read_exit_k_and_alarms(dut)
    assert (answer, exit_k, alarms) == (5, 2, 0), f"after restart: answer={answer} exit_k={exit_k} alarms={alarms:05b}"


@cocotb.test()
async def test_scan_busy_drain_visible(dut):
    """After an early exit the pixel scanner keeps running the plane it is on. View 2
    bit 3 (SCAN_BUSY) reports it, and it falls within the documented 52 cycles."""
    await reset(dut)
    await load_blob(dut, mkblob())
    answer, cycles = await run_image(dut, IMG_EARLY)
    assert answer == 5
    dut.uio_in.value = ctrl(dft=2)
    await FallingEdge(dut.clk)
    assert (view(dut) >> 3) & 1 == 1, "SCAN_BUSY low right after an early-exit DONE: the drain is not reported"
    for n in range(60):
        await FallingEdge(dut.clk)
        if (view(dut) >> 3) & 1 == 0:
            break
    else:
        raise AssertionError("SCAN_BUSY still high 60 cycles after DONE")
    dut._log.info(f"scanner drained {n + 1} cycles after DONE")
    assert n + 1 <= 52, f"drain took {n + 1} cycles, contract says at most 52"
    # With the scanner idle, the next image runs clean: no scan_err.
    dut.uio_in.value = 0
    await FallingEdge(dut.clk)
    answer, cycles = await run_image(dut, IMG_FULL)
    exit_k, alarms = await read_exit_k_and_alarms(dut)
    assert (answer, exit_k, alarms) == (5, 0, 0), f"second image: answer={answer} exit_k={exit_k} alarms={alarms:05b}"


@cocotb.test()
async def test_ncap_below_planes_is_reported(dut):
    """N_cap = 2 cannot be served (the final checkpoint is always at plane 4). It must be
    clamped to 4 and reported on cap_err, not swallowed: the chip then still answers
    when all four planes are fed."""
    await reset(dut)
    await load_blob(dut, mkblob(ncap=2))
    dut.uio_in.value = ctrl(dft=3)
    await FallingEdge(dut.clk)
    assert view(dut) & 0x1F == 0, "an alarm before START"
    dut.uio_in.value = 0
    await FallingEdge(dut.clk)
    answer, cycles = await run_image(dut, IMG_FULL)
    exit_k, alarms = await read_exit_k_and_alarms(dut)
    assert answer == 5 and exit_k == 0, f"answer={answer} exit_k={exit_k}"
    assert alarms == 0b10000, f"expected only cap_err (bit 4) set, got {alarms:05b}"
    dut.uio_in.value = ctrl(dft=0)
    await FallingEdge(dut.clk)
    assert (view(dut) >> 7) & 1 == 1, "ERR pin low although cap_err is set"
