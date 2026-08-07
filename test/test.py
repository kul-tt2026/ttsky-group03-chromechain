# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, with_timeout
from cocotb.result import SimTimeoutError


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    # 100 kHz klok
    clock = Clock(dut.clk, 10, unit="us")
    cocotb.start_soon(clock.start())

    # Reset
    dut._log.info("Reset")
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)

    # --- Start een nieuwe classificatie ---
    dut._log.info("Pulse start")
    dut.ui_in.value = 0b00000001   # start = ui_in[0]
    await ClockCycles(dut.clk, 1)
    dut.ui_in.value = 0
    await ClockCycles(dut.clk, 2)

    # --- Stuur 16 windows, elk met minstens één non-zero pixel ---
    # window_in = {uio_in, ui_in} (16 bits), window_valid = ui_in[1]
    # We gebruiken simpele, gegarandeerd non-zero testdata per window.
    for window_idx in range(16):
        # elk window krijgt een klein, uniek, gegarandeerd non-zero patroon
        pixel_data = (0x1111 + window_idx) & 0xFFFF

        uio_val = (pixel_data >> 8) & 0xFF
        ui_val_data = pixel_data & 0xFF

        dut.uio_in.value = uio_val
        # ui_in[1] (window_valid) hoog zetten, data staat op de rest van ui_in
        dut.ui_in.value = (ui_val_data & 0b11111100) | 0b10

        dut._log.info(f"Window {window_idx}: pixel_data=0x{pixel_data:04x}")
        await ClockCycles(dut.clk, 1)

        # window_valid weer laag
        dut.ui_in.value = ui_val_data & 0b11111100
        dut.uio_in.value = 0

        # Ruime marge geven aan de scan/accumulate-fase voordat het volgende window komt
        # (zonder zichtbare window_req moeten we hier gokken/ruim inschatten)
        await ClockCycles(dut.clk, 50)

    # --- Wacht op result_valid (bit 4 van uo_out volgens huidige mapping) ---
    dut._log.info("Waiting for result_valid...")

    timeout_cycles = 2000
    for i in range(timeout_cycles):
        await ClockCycles(dut.clk, 1)
        uo = dut.uo_out.value
        result_valid = (int(uo) >> 4) & 0x1
        if result_valid:
            result = int(uo) & 0xF
            dut._log.info(f"result_valid=1 na {i} extra cycles, result={result}")
            break
    else:
        assert False, f"result_valid werd niet hoog binnen {timeout_cycles} cycles — pipeline lijkt vast te lopen"

    dut._log.info("Test compleet: pipeline liep van start tot result_valid zonder vast te lopen.")
