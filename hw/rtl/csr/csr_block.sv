//-----------------------------------------------------------------------------
// File: csr_block.sv
// Description: Control/Status Register block with Avalon-MM slave interface.
//              Provides configuration and status access for all pipeline stages.
//
// Register Map: See docs/register_map.md for full documentation
//
// Features:
//   - 4KB address space (BAR0)
//   - Read/write configuration registers
//   - Read-only status and statistics registers
//   - Clear-on-read counters
//   - Latency histogram access
//
// Author: T2T Project
// Date: 2025-01-30
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module csr_block #(
    parameter int unsigned ADDR_WIDTH = 12,
    parameter int unsigned DATA_WIDTH = 32
) (
    input  logic                    clk,           // csr_clk (100 MHz)
    input  logic                    rst_n,
    
    //-------------------------------------------------------------------------
    // Avalon-MM Slave Interface
    //-------------------------------------------------------------------------
    input  logic [ADDR_WIDTH-1:0]   avmm_address,
    input  logic [DATA_WIDTH-1:0]   avmm_writedata,
    input  logic [DATA_WIDTH/8-1:0] avmm_byteenable,
    input  logic                    avmm_write,
    input  logic                    avmm_read,
    output logic [DATA_WIDTH-1:0]   avmm_readdata,
    output logic                    avmm_waitrequest,
    output logic                    avmm_readdatavalid,
    
    //-------------------------------------------------------------------------
    // Configuration Outputs (directly usable by other modules)
    //-------------------------------------------------------------------------
    output logic                    cfg_enable,
    output logic                    cfg_promiscuous,
    output logic [47:0]             cfg_mcast_mac,
    output logic                    cfg_mcast_enable,
    output logic                    cfg_check_ip_csum,
    output logic [15:0]             cfg_expected_port,
    output logic [15:0]             cfg_price_band_bps,
    output logic [15:0]             cfg_token_rate,
    output logic [15:0]             cfg_token_max,
    output logic signed [31:0]      cfg_position_limit,
    output logic [31:0]             cfg_stale_cycles,
    output logic                    cfg_kill_switch,
    output logic [31:0]             cfg_expected_seq,
    output logic                    cfg_seq_check_en,
    
    // Ring buffer configuration
    output logic [63:0]             cfg_ring_base,
    output logic [15:0]             cfg_ring_size,
    output logic                    cfg_msix_enable,
    output logic [15:0]             cfg_msix_threshold,
    
    // Symbol table interface
    output logic [63:0]             symtab_key,
    output logic [9:0]              symtab_idx,
    output logic                    symtab_load,
    output logic                    symtab_commit,
    
    // Reference price interface
    output logic [9:0]              ref_price_addr,
    output logic [31:0]             ref_price_data,
    output logic                    ref_price_we,
    
    //-------------------------------------------------------------------------
    // Status Inputs (directly readable)
    //-------------------------------------------------------------------------
    input  logic [15:0]             status_prod_idx,
    output logic [15:0]             status_cons_idx,
    input  logic                    status_ring_full,
    input  logic                    status_ring_empty,
    input  logic                    status_stale,
    
    // Statistics inputs (directly readable)
    input  logic [31:0]             stat_rx_packets,
    input  logic [31:0]             stat_rx_bytes,
    input  logic [31:0]             stat_rx_crc_errors,
    input  logic [31:0]             stat_rx_drops,
    input  logic [31:0]             stat_parsed_packets,
    input  logic [31:0]             stat_messages,
    input  logic [31:0]             stat_seq_gaps,
    input  logic [31:0]             stat_book_updates,
    input  logic [31:0]             stat_bank_conflicts,
    input  logic [31:0]             stat_risk_accepts,
    input  logic [31:0]             stat_risk_rejects,
    input  logic [31:0]             stat_dma_records,
    input  logic [31:0]             stat_dma_drops,
    
    // Latency histogram interface
    input  logic [31:0]             lat_hist_data,
    output logic [7:0]              lat_hist_addr,
    output logic                    lat_hist_rd,
    
    //-------------------------------------------------------------------------
    // Build Information
    //-------------------------------------------------------------------------
    input  logic [31:0]             build_timestamp,
    input  logic [31:0]             build_git_hash
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    
    localparam logic [31:0] BUILD_ID = 32'hT2T1_0001;  // Version 1.0.01
    
    //=========================================================================
    // Register Definitions
    //=========================================================================
    
    // Control registers
    logic [31:0] reg_ctrl;
    logic [31:0] reg_price_band_bps;
    logic [31:0] reg_token_rate;
    logic [31:0] reg_position_limit;
    logic [31:0] reg_stale_usec;
    logic [31:0] reg_seq_gap_thr;
    logic [31:0] reg_kill;
    logic [31:0] reg_expected_seq;
    logic [31:0] reg_expected_port;
    
    // MAC config
    logic [31:0] reg_mcast_mac_lo;
    logic [31:0] reg_mcast_mac_hi;
    
    // Ring config
    logic [31:0] reg_ring_base_lo;
    logic [31:0] reg_ring_base_hi;
    logic [31:0] reg_ring_len;
    logic [31:0] reg_cons_idx;
    logic [31:0] reg_msix_cfg;
    
    // Symbol table staging
    logic [31:0] reg_symtab_data [4];  // 4 x 32-bit = 128 bits for key + idx
    logic [31:0] reg_symtab_commit;
    
    // Reference price staging
    logic [31:0] reg_ref_price_data;
    logic [31:0] reg_ref_price_addr;
    
    // Read data mux
    logic [31:0] read_data;
    logic        read_valid;
    
    //=========================================================================
    // Write Logic
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_ctrl           <= 32'h0000_0000;
            reg_price_band_bps <= 32'h0000_01F4;  // 500 bps default
            reg_token_rate     <= 32'h0000_03E8;  // 1000 tokens/ms
            reg_position_limit <= 32'h000F_4240;  // 1M default
            reg_stale_usec     <= 32'h0001_86A0;  // 100ms
            reg_seq_gap_thr    <= 32'h0000_0064;  // 100 gaps
            reg_kill           <= 32'h0000_0000;
            reg_expected_seq   <= 32'h0000_0001;
            reg_expected_port  <= 32'h0000_0000;
            reg_mcast_mac_lo   <= 32'h0000_0000;
            reg_mcast_mac_hi   <= 32'h0000_0000;
            reg_ring_base_lo   <= 32'h0000_0000;
            reg_ring_base_hi   <= 32'h0000_0000;
            reg_ring_len       <= 32'h0001_0000;  // 64K entries
            reg_cons_idx       <= 32'h0000_0000;
            reg_msix_cfg       <= 32'h0000_0100;  // Threshold = 256
            reg_symtab_commit  <= 32'h0000_0000;
            
            for (int i = 0; i < 4; i++) begin
                reg_symtab_data[i] <= 32'h0000_0000;
            end
            
            reg_ref_price_data <= 32'h0000_0000;
            reg_ref_price_addr <= 32'h0000_0000;
            
            symtab_load   <= 1'b0;
            symtab_commit <= 1'b0;
            ref_price_we  <= 1'b0;
        end else begin
            // Default: clear one-shot signals
            symtab_load   <= 1'b0;
            symtab_commit <= 1'b0;
            ref_price_we  <= 1'b0;
            
            if (avmm_write) begin
                case (avmm_address)
                    CSR_CTRL:            reg_ctrl           <= avmm_writedata;
                    CSR_PRICE_BAND_BPS:  reg_price_band_bps <= avmm_writedata;
                    CSR_TOKEN_RATE:      reg_token_rate     <= avmm_writedata;
                    CSR_POSITION_LIMIT:  reg_position_limit <= avmm_writedata;
                    CSR_STALE_USEC:      reg_stale_usec     <= avmm_writedata;
                    CSR_SEQ_GAP_THR:     reg_seq_gap_thr    <= avmm_writedata;
                    CSR_KILL:            reg_kill           <= avmm_writedata;
                    
                    12'h050:             reg_expected_seq   <= avmm_writedata;
                    12'h054:             reg_expected_port  <= avmm_writedata;
                    12'h058:             reg_mcast_mac_lo   <= avmm_writedata;
                    12'h05C:             reg_mcast_mac_hi   <= avmm_writedata;
                    
                    // Symbol table data staging
                    CSR_SYMTAB_DATA:     reg_symtab_data[0] <= avmm_writedata;
                    12'h024:             reg_symtab_data[1] <= avmm_writedata;
                    12'h028:             reg_symtab_data[2] <= avmm_writedata;
                    12'h02C:             reg_symtab_data[3] <= avmm_writedata;
                    
                    // Symbol table commit (triggers load)
                    CSR_SYMTAB_COMMIT: begin
                        if (avmm_writedata[0]) begin
                            symtab_load <= 1'b1;
                        end
                        if (avmm_writedata[1]) begin
                            symtab_commit <= 1'b1;
                        end
                    end
                    
                    // Reference price
                    12'h060:             reg_ref_price_addr <= avmm_writedata;
                    12'h064: begin
                        reg_ref_price_data <= avmm_writedata;
                        ref_price_we       <= 1'b1;
                    end
                    
                    // Ring configuration
                    CSR_RING_BASE_LO:    reg_ring_base_lo   <= avmm_writedata;
                    CSR_RING_BASE_HI:    reg_ring_base_hi   <= avmm_writedata;
                    CSR_RING_LEN:        reg_ring_len       <= avmm_writedata;
                    CSR_CONS_IDX_SHADOW: reg_cons_idx       <= avmm_writedata;
                    CSR_MSIX_CFG:        reg_msix_cfg       <= avmm_writedata;
                    
                    default: ;  // Ignore writes to unknown/read-only registers
                endcase
            end
        end
    end
    
    //=========================================================================
    // Read Logic
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_data  <= '0;
            read_valid <= 1'b0;
            lat_hist_rd <= 1'b0;
            lat_hist_addr <= '0;
        end else begin
            read_valid  <= avmm_read;
            lat_hist_rd <= 1'b0;
            
            if (avmm_read) begin
                case (avmm_address)
                    // Read-only: Build info
                    CSR_BUILD_ID:        read_data <= BUILD_ID;
                    12'h0F0:             read_data <= build_timestamp;
                    12'h0F4:             read_data <= build_git_hash;
                    
                    // Read/write: Config
                    CSR_CTRL:            read_data <= reg_ctrl;
                    CSR_PRICE_BAND_BPS:  read_data <= reg_price_band_bps;
                    CSR_TOKEN_RATE:      read_data <= reg_token_rate;
                    CSR_POSITION_LIMIT:  read_data <= reg_position_limit;
                    CSR_STALE_USEC:      read_data <= reg_stale_usec;
                    CSR_SEQ_GAP_THR:     read_data <= reg_seq_gap_thr;
                    CSR_KILL:            read_data <= reg_kill;
                    
                    12'h050:             read_data <= reg_expected_seq;
                    12'h054:             read_data <= reg_expected_port;
                    12'h058:             read_data <= reg_mcast_mac_lo;
                    12'h05C:             read_data <= reg_mcast_mac_hi;
                    
                    // Ring config/status
                    CSR_RING_BASE_LO:    read_data <= reg_ring_base_lo;
                    CSR_RING_BASE_HI:    read_data <= reg_ring_base_hi;
                    CSR_RING_LEN:        read_data <= reg_ring_len;
                    CSR_PROD_IDX:        read_data <= {16'b0, status_prod_idx};
                    CSR_CONS_IDX_SHADOW: read_data <= reg_cons_idx;
                    CSR_MSIX_CFG:        read_data <= reg_msix_cfg;
                    
                    // Read-only: Status
                    12'h0E0:             read_data <= {30'b0, status_ring_full, status_ring_empty};
                    12'h0E4:             read_data <= {31'b0, status_stale};
                    
                    // Read-only: Statistics
                    CSR_DROPS:           read_data <= stat_rx_drops;
                    CSR_CRC_BAD:         read_data <= stat_rx_crc_errors;
                    CSR_SEQ_GAPS:        read_data <= stat_seq_gaps;
                    CSR_ACCEPTS:         read_data <= stat_risk_accepts;
                    CSR_BLOCKS:          read_data <= stat_risk_rejects;
                    
                    12'h194:             read_data <= stat_rx_packets;
                    12'h198:             read_data <= stat_rx_bytes;
                    12'h19C:             read_data <= stat_parsed_packets;
                    12'h1A0:             read_data <= stat_messages;
                    12'h1A4:             read_data <= stat_book_updates;
                    12'h1A8:             read_data <= stat_bank_conflicts;
                    12'h1AC:             read_data <= stat_dma_records;
                    12'h1B0:             read_data <= stat_dma_drops;
                    
                    // Latency histogram (256 bins)
                    default: begin
                        if (avmm_address >= CSR_LAT_HIST_BASE && 
                            avmm_address < CSR_LAT_HIST_BASE + 12'h080) begin
                            lat_hist_addr <= avmm_address[9:2];
                            lat_hist_rd   <= 1'b1;
                            read_data     <= lat_hist_data;
                        end else begin
                            read_data <= 32'hDEAD_BEEF;  // Unknown register
                        end
                    end
                endcase
            end
        end
    end
    
    //=========================================================================
    // Output Assignments
    //=========================================================================
    
    // Control register fields
    assign cfg_enable        = reg_ctrl[0];
    assign cfg_promiscuous   = reg_ctrl[1];
    assign cfg_mcast_enable  = reg_ctrl[2];
    assign cfg_check_ip_csum = reg_ctrl[3];
    assign cfg_seq_check_en  = reg_ctrl[4];
    assign cfg_msix_enable   = reg_ctrl[5];
    
    // Other configs
    assign cfg_price_band_bps = reg_price_band_bps[15:0];
    assign cfg_token_rate     = reg_token_rate[15:0];
    assign cfg_token_max      = reg_token_rate[31:16];
    assign cfg_position_limit = reg_position_limit;
    assign cfg_stale_cycles   = reg_stale_usec * 300;  // Convert to cycles at 300 MHz
    assign cfg_kill_switch    = reg_kill[0];
    assign cfg_expected_seq   = reg_expected_seq;
    assign cfg_expected_port  = reg_expected_port[15:0];
    
    assign cfg_mcast_mac      = {reg_mcast_mac_hi[15:0], reg_mcast_mac_lo};
    
    assign cfg_ring_base      = {reg_ring_base_hi, reg_ring_base_lo};
    assign cfg_ring_size      = reg_ring_len[15:0];
    assign cfg_msix_threshold = reg_msix_cfg[15:0];
    
    assign status_cons_idx    = reg_cons_idx[15:0];
    
    // Symbol table interface
    assign symtab_key         = {reg_symtab_data[1], reg_symtab_data[0]};
    assign symtab_idx         = reg_symtab_data[2][9:0];
    
    // Reference price interface
    assign ref_price_addr     = reg_ref_price_addr[9:0];
    assign ref_price_data     = reg_ref_price_data;
    
    // Avalon-MM interface
    assign avmm_readdata      = read_data;
    assign avmm_waitrequest   = 1'b0;  // Always ready
    assign avmm_readdatavalid = read_valid;

endmodule : csr_block
