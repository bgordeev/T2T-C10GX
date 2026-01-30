# Makefile for T2T-C10GX cocotb Testbenches
#
# Usage:
#   make                    # Run all tests with Verilator
#   make SIM=questa         # Run with Questa/ModelSim
#   make test_itch_decoder  # Run specific test
#   make clean              # Clean build artifacts

# Default simulator
SIM ?= verilator
TOPLEVEL_LANG ?= verilog

# Paths
RTL_DIR = ../rtl
PKG_DIR = $(RTL_DIR)/pkg
COMMON_DIR = $(RTL_DIR)/common
PARSER_DIR = $(RTL_DIR)/parser
BOOK_DIR = $(RTL_DIR)/book
RISK_DIR = $(RTL_DIR)/risk
TOP_DIR = $(RTL_DIR)/top

# Common source files
VERILOG_SOURCES += $(PKG_DIR)/t2t_pkg.sv
VERILOG_SOURCES += $(COMMON_DIR)/cdc_sync.sv
VERILOG_SOURCES += $(COMMON_DIR)/axi_async_fifo.sv

# Simulator-specific settings
ifeq ($(SIM),verilator)
    EXTRA_ARGS += --trace --trace-structs
    EXTRA_ARGS += -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDSIGNAL
    EXTRA_ARGS += -Wno-TIMESCALEMOD -Wno-UNOPTFLAT
    COMPILE_ARGS += --timing
endif

ifeq ($(SIM),questa)
    EXTRA_ARGS += +acc
    EXTRA_ARGS += -suppress 12003
endif

# Include cocotb's Makefile
include $(shell cocotb-config --makefiles)/Makefile.sim

# Test Targets

.PHONY: test_itch_decoder test_book_tob test_risk_gate test_pipeline test_all

test_itch_decoder: MODULE = test_itch_decoder
test_itch_decoder: TOPLEVEL = itch_decoder
test_itch_decoder: VERILOG_SOURCES += $(PARSER_DIR)/itch_decoder.sv
test_itch_decoder:
	$(MAKE) sim

test_itch_splitter: MODULE = test_itch_splitter
test_itch_splitter: TOPLEVEL = itch_splitter
test_itch_splitter: VERILOG_SOURCES += $(PARSER_DIR)/itch_splitter.sv
test_itch_splitter:
	$(MAKE) sim

test_symtab: MODULE = test_symtab
test_symtab: TOPLEVEL = symtab_cam
test_symtab: VERILOG_SOURCES += $(PARSER_DIR)/symtab_cam.sv
test_symtab:
	$(MAKE) sim

test_book_tob: MODULE = test_book_tob
test_book_tob: TOPLEVEL = book_tob
test_book_tob: VERILOG_SOURCES += $(BOOK_DIR)/book_tob.sv
test_book_tob:
	$(MAKE) sim

test_risk_gate: MODULE = test_risk_gate
test_risk_gate: TOPLEVEL = risk_gate
test_risk_gate: VERILOG_SOURCES += $(RISK_DIR)/risk_gate.sv
test_risk_gate:
	$(MAKE) sim

test_pipeline: MODULE = test_pipeline
test_pipeline: TOPLEVEL = t2t_top
test_pipeline: VERILOG_SOURCES += $(RTL_DIR)/mac/mac_wrap.sv
test_pipeline: VERILOG_SOURCES += $(PARSER_DIR)/l2l3l4_parser.sv
test_pipeline: VERILOG_SOURCES += $(PARSER_DIR)/itch_splitter.sv
test_pipeline: VERILOG_SOURCES += $(PARSER_DIR)/itch_decoder.sv
test_pipeline: VERILOG_SOURCES += $(PARSER_DIR)/symtab_cam.sv
test_pipeline: VERILOG_SOURCES += $(BOOK_DIR)/book_tob.sv
test_pipeline: VERILOG_SOURCES += $(RISK_DIR)/risk_gate.sv
test_pipeline: VERILOG_SOURCES += $(RTL_DIR)/pcie/pcie_dma.sv
test_pipeline: VERILOG_SOURCES += $(RTL_DIR)/csr/csr_block.sv
test_pipeline: VERILOG_SOURCES += $(COMMON_DIR)/timestamp_counter.sv
test_pipeline: VERILOG_SOURCES += $(TOP_DIR)/t2t_top.sv
test_pipeline:
	$(MAKE) sim

test_all: test_itch_decoder test_itch_splitter test_symtab test_book_tob test_risk_gate test_pipeline

# Utility Targets

.PHONY: lint waves clean-all

lint:
	verilator --lint-only -Wall \
		-I$(PKG_DIR) \
		$(VERILOG_SOURCES) \
		$(TOP_DIR)/t2t_top.sv

waves:
	gtkwave dump.vcd &

clean-all: clean
	rm -rf __pycache__ .pytest_cache
	rm -rf sim_build results.xml
	rm -f *.vcd *.fst *.log
