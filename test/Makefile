# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info

# Defaults
SIM             ?= icarus
FST             ?= -fst # Use more efficient FST format
TOPLEVEL_LANG   ?= verilog
SRC_DIR          = $(PWD)/../src
PROJECT_SOURCES  = tt_um_kul_chromechain.v \
                   cc_top.v \
                   top_fsm.v \
                   blob_loader.v \
                   w1_rom_final4.v \
                   ckpt_block.v \
                   bitplane_buffer.v \
                   popcount.v \
                   active_pixel_scan.v \
                   l1_horner_acc.v \
                   l1_horner_cnt.v \
                   l1_acc_shadow.v \
                   l1_acc_shadow_cg.v \
                   checkpoint_ctrl.v \
                   requant_rom_x4.v \
                   l2_weight_rom_x4.v \
                   config_latch.v \
                   requant_unit.v \
                   l2_mac_x4.v \
                   max2_node.v \
                   exit_tree_2stage.v

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD        = sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# Gate level simulation:
SIM_BUILD        = sim_build/gl
PDK_PATH        := $(shell find $(PDK_ROOT) -maxdepth 5 -type d -name $(PDK) 2>/dev/null | head -1)
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_PATH)/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_PATH)/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v

# This gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

endif

# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL         = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# Include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim

# Extend cocotb's clean target to also remove build artifacts
.PHONY: clean
clean::
	rm -rf sim_build/ __pycache__/ results.xml tb.fst
