//-----------------------------------------------------------------------------
// File: csr_avalon.sv
// Description: Control and Status Register block with Avalon-MM slave interface.
//              Implements the CSR map for configuration, monitoring, and
//              symbol table management.
//
// Avalon-MM Interface:
//   - 32-bit data width
//   - Byte addressing (word-aligned)
//   - Single-cycle read/write for most registers
//   - Multi-cycle for histogram and symbol table access
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module csr_avalon #(
    parameter logic [31:0] BUILD_ID = 32'h20250130  // Default build timestamp
) (
    input  logic                    clk,
    input  logic                    rst_n,
    
    //-------------------------------------------------------------------------
    // Avalon-MM Slave Interface
    //-------------------------------------------------------------------------
    input  logic [11:0]             avs_address,      // Byte address
    input  logic                    avs_read,
    input  logic                    avs_write,
    input  logic [31:0]             avs_writedata,
    input  logic [3:0]              avs_byteenable,
    output logic [31:0]             avs_readdata,
    output logic                    avs_readdatavalid,
    output logic                    avs_waitrequest,
    
    //-------------------------------------------------------------------------
    // Configuration Outputs (directly usable, active on csr_clk)
    //-------------------------------------------------------------------------
    output logic                    cfg_enable,
    output logic                    cfg_clear_stats,
    output logic                    cfg_gpio_enable,
    output logic [15:0]             cfg_price_band_bps,
    output logic [15:0]             cfg_token_rate,
    output logic signed [31:0]      cfg_position_limit,
    output logic [31:0]             cfg_stale_usec,
    output logic [15:0]             cfg_seq_gap_thr,
    output logic                    cfg_kill,
    
    //-------------------------------------------------------------------------
    // Symbol Table Interface
    //-------------------------------------------------------------------------
    output logic [63:0]             symtab_key,
    output logic [9:0]              symtab_idx,
    output logic                    symtab_write,
    output logic                    symtab_commit,
    input  logic                    symtab_ready,
    
    //-------------------------------------------------------------------------
    // Ring Buffer Configuration
    //-------------------------------------------------------------------------
    output logic [63:0]             ring_base_addr,
    output logic [15:0]             ring_length,
    input  logic [15:0]             ring_prod_idx,
    output logic [15:0]             ring_cons_idx_shadow,
    
    //-------------------------------------------------------------------------
    // MSI-X Configuration
    //-------------------------------------------------------------------------
    output logic [31:0]             msix_cfg,
    
    //-------------------------------------------------------------------------
    // Statistics Inputs (directly from core_clk domain, synchronized here)
    //-------------------------------------------------------------------------
    input  logic [31:0]             stat_rx_packets,
    input  logic [31:0]             stat_drops,
    input  logic [31:0]             stat_crc_bad,
    input  logic [31:0]             stat_seq_gaps,
    input  logic [31:0]             stat_accepts,
    input  logic [31:0]             stat_blocks,
    
    //-------------------------------------------------------------------------
    // Latency Histogram Interface
    //-------------------------------------------------------------------------
    output logic [7:0]              hist_addr,
    output logic                    hist_rd,
    input  logic [31:0]             hist_data,
    input  logic                    hist_valid,
    
    //-------------------------------------------------------------------------
    // Event Log Interface
    //-------------------------------------------------------------------------
    output logic                    event_log_rd,
    input  logic [63:0]             event_log_data,
    input  logic                    event_log_valid,
    input  logic                    event_log_empty
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    
    // Register addresses (word-aligned, using byte addresses)
    localparam logic [11:0] ADDR_BUILD_ID        = 12'h000;
    localparam logic [11:0] ADDR_CTRL            = 12'h004;
    localparam logic [11:0] ADDR_PRICE_BAND_BPS  = 12'h008;
    localparam logic [11:0] ADDR_TOKEN_RATE      = 12'h00C;
    localparam logic [11:0] ADDR_POSITION_LIMIT  = 12'h010;
    localparam logic [11:0] ADDR_STALE_USEC      = 12'h014;
    localparam logic [11:0] ADDR_SEQ_GAP_THR     = 12'h018;
    localparam logic [11:0] ADDR_KILL            = 12'h01C;
    localparam logic [11:0] ADDR_SYMTAB_DATA_LO  = 12'h020;
    localparam logic [11:0] ADDR_SYMTAB_DATA_HI  = 12'h024;
    localparam logic [11:0] ADDR_SYMTAB_IDX      = 12'h028;
    localparam logic [11:0] ADDR_SYMTAB_COMMIT   = 12'h040;
    localparam logic [11:0] ADDR_LAT_HIST_BASE   = 12'h100;
    localparam logic [11:0] ADDR_LAT_HIST_END    = 12'h17F;
    localparam logic [11:0] ADDR_DROPS           = 12'h180;
    localparam logic [11:0] ADDR_CRC_BAD         = 12'h184;
    localparam logic [11:0] ADDR_SEQ_GAPS        = 12'h188;
    localparam logic [11:0] ADDR_ACCEPTS         = 12'h18C;
    localparam logic [11:0] ADDR_BLOCKS          = 12'h190;
    localparam logic [11:0] ADDR_RX_PACKETS      = 12'h194;
    localparam logic [11:0] ADDR_EVENT_LOG       = 12'h200;
    localparam logic [11:0] ADDR_RING_BASE_LO    = 12'h300;
    localparam logic [11:0] ADDR_RING_BASE_HI    = 12'h304;
    localparam logic [11:0] ADDR_RING_LEN        = 12'h308;
    localparam logic [11:0] ADDR_PROD_IDX        = 12'h320;
    localparam logic [11:0] ADDR_CONS_IDX_SHADOW = 12'h324;
    localparam logic [11:0] ADDR_MSIX_CFG        = 12'h328;
    
    //=========================================================================
    // Signal Declarations
    //=========================================================================
    
    // Registered configuration
    logic [31:0] ctrl_reg;
    logic [31:0] price_band_reg;
    logic [31:0] token_rate_reg;
    logic [31:0] position_limit_reg;
    logic [31:0] stale_usec_reg;
    logic [31:0] seq_gap_thr_reg;
    logic [31:0] kill_reg;
    logic [63:0] symtab_data_reg;
    logic [31:0] symtab_idx_reg;
    logic [63:0] ring_base_reg;
    logic [31:0] ring_len_reg;
    logic [31:0] cons_idx_shadow_reg;
    logic [31:0] msix_cfg_reg;
    
    // Read data mux
    logic [31:0] rd_data_next;
    logic        rd_valid_next;
    logic        wait_request;
    
    // Multi-cycle access state
    typedef enum logic [1:0] {
        ACC_IDLE,
        ACC_HIST_WAIT,
        ACC_EVENT_WAIT
    } acc_state_e;
    
    acc_state_e acc_state;
    
    //=========================================================================
    // Configuration Register Outputs
    //=========================================================================
    
    assign cfg_enable         = ctrl_reg[0];
    assign cfg_clear_stats    = ctrl_reg[1];
    assign cfg_gpio_enable    = ctrl_reg[2];
    assign cfg_price_band_bps = price_band_reg[15:0];
    assign cfg_token_rate     = token_rate_reg[15:0];
    assign cfg_position_limit = position_limit_reg;
    assign cfg_stale_usec     = stale_usec_reg;
    assign cfg_seq_gap_thr    = seq_gap_thr_reg[15:0];
    assign cfg_kill           = kill_reg[0];
    
    assign ring_base_addr       = ring_base_reg;
    assign ring_length          = ring_len_reg[15:0];
    assign ring_cons_idx_shadow = cons_idx_shadow_reg[15:0];
    assign msix_cfg             = msix_cfg_reg;
    
    //=========================================================================
    // Write Logic
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_reg           <= 32'h0;
            price_band_reg     <= 32'd500;      // Default 500 bps
            token_rate_reg     <= 32'd1000;     // Default 1000 tokens/ms
            position_limit_reg <= 32'd1000000;  // Default 1M notional
            stale_usec_reg     <= 32'd100000;   // Default 100ms
            seq_gap_thr_reg    <= 32'd100;      // Default gap threshold
            kill_reg           <= 32'h0;
            symtab_data_reg    <= 64'h0;
            symtab_idx_reg     <= 32'h0;
            ring_base_reg      <= 64'h0;
            ring_len_reg       <= 32'd65536;    // Default ring size
            cons_idx_shadow_reg <= 32'h0;
            msix_cfg_reg       <= 32'h0;
            
            symtab_write  <= 1'b0;
            symtab_commit <= 1'b0;
        end else begin
            // Clear single-cycle pulses
            symtab_write  <= 1'b0;
            symtab_commit <= 1'b0;
            
            // Auto-clear stats clear bit
            if (ctrl_reg[1]) begin
                ctrl_reg[1] <= 1'b0;
            end
            
            if (avs_write && !wait_request) begin
                case (avs_address)
                    ADDR_CTRL:            ctrl_reg           <= avs_writedata;
                    ADDR_PRICE_BAND_BPS:  price_band_reg     <= avs_writedata;
                    ADDR_TOKEN_RATE:      token_rate_reg     <= avs_writedata;
                    ADDR_POSITION_LIMIT:  position_limit_reg <= avs_writedata;
                    ADDR_STALE_USEC:      stale_usec_reg     <= avs_writedata;
                    ADDR_SEQ_GAP_THR:     seq_gap_thr_reg    <= avs_writedata;
                    ADDR_KILL:            kill_reg           <= avs_writedata;
                    ADDR_SYMTAB_DATA_LO:  symtab_data_reg[31:0]  <= avs_writedata;
                    ADDR_SYMTAB_DATA_HI:  symtab_data_reg[63:32] <= avs_writedata;
                    ADDR_SYMTAB_IDX: begin
                        symtab_idx_reg <= avs_writedata;
                        symtab_write   <= 1'b1;
                    end
                    ADDR_SYMTAB_COMMIT:   symtab_commit      <= avs_writedata[0];
                    ADDR_RING_BASE_LO:    ring_base_reg[31:0]  <= avs_writedata;
                    ADDR_RING_BASE_HI:    ring_base_reg[63:32] <= avs_writedata;
                    ADDR_RING_LEN:        ring_len_reg       <= avs_writedata;
                    ADDR_CONS_IDX_SHADOW: cons_idx_shadow_reg <= avs_writedata;
                    ADDR_MSIX_CFG:        msix_cfg_reg       <= avs_writedata;
                    default: ;  // Ignore writes to RO registers
                endcase
            end
        end
    end
    
    // Symbol table interface
    assign symtab_key = symtab_data_reg;
    assign symtab_idx = symtab_idx_reg[9:0];
    
    //=========================================================================
    // Read Logic and State Machine
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_state         <= ACC_IDLE;
            avs_readdata      <= '0;
            avs_readdatavalid <= 1'b0;
            hist_rd           <= 1'b0;
            event_log_rd      <= 1'b0;
        end else begin
            avs_readdatavalid <= 1'b0;
            hist_rd           <= 1'b0;
            event_log_rd      <= 1'b0;
            
            case (acc_state)
                ACC_IDLE: begin
                    if (avs_read) begin
                        // Check if this is a multi-cycle access
                        if (avs_address >= ADDR_LAT_HIST_BASE && 
                            avs_address <= ADDR_LAT_HIST_END) begin
                            // Histogram read
                            hist_addr <= avs_address[7:0] - ADDR_LAT_HIST_BASE[7:0];
                            hist_rd   <= 1'b1;
                            acc_state <= ACC_HIST_WAIT;
                        end else if (avs_address == ADDR_EVENT_LOG) begin
                            // Event log read
                            event_log_rd <= 1'b1;
                            acc_state    <= ACC_EVENT_WAIT;
                        end else begin
                            // Single-cycle read
                            avs_readdata      <= rd_data_next;
                            avs_readdatavalid <= 1'b1;
                        end
                    end
                end
                
                ACC_HIST_WAIT: begin
                    if (hist_valid) begin
                        avs_readdata      <= hist_data;
                        avs_readdatavalid <= 1'b1;
                        acc_state         <= ACC_IDLE;
                    end
                end
                
                ACC_EVENT_WAIT: begin
                    if (event_log_valid) begin
                        avs_readdata      <= event_log_data[31:0];  // Return lower 32 bits
                        avs_readdatavalid <= 1'b1;
                        acc_state         <= ACC_IDLE;
                    end else if (event_log_empty) begin
                        avs_readdata      <= 32'hFFFFFFFF;  // Empty marker
                        avs_readdatavalid <= 1'b1;
                        acc_state         <= ACC_IDLE;
                    end
                end
            endcase
        end
    end
    
    // Combinational read data mux for single-cycle registers
    always_comb begin
        rd_data_next = 32'h0;
        
        case (avs_address)
            ADDR_BUILD_ID:        rd_data_next = BUILD_ID;
            ADDR_CTRL:            rd_data_next = ctrl_reg;
            ADDR_PRICE_BAND_BPS:  rd_data_next = price_band_reg;
            ADDR_TOKEN_RATE:      rd_data_next = token_rate_reg;
            ADDR_POSITION_LIMIT:  rd_data_next = position_limit_reg;
            ADDR_STALE_USEC:      rd_data_next = stale_usec_reg;
            ADDR_SEQ_GAP_THR:     rd_data_next = seq_gap_thr_reg;
            ADDR_KILL:            rd_data_next = kill_reg;
            ADDR_SYMTAB_DATA_LO:  rd_data_next = symtab_data_reg[31:0];
            ADDR_SYMTAB_DATA_HI:  rd_data_next = symtab_data_reg[63:32];
            ADDR_SYMTAB_IDX:      rd_data_next = symtab_idx_reg;
            ADDR_SYMTAB_COMMIT:   rd_data_next = {31'b0, symtab_ready};
            ADDR_DROPS:           rd_data_next = stat_drops;
            ADDR_CRC_BAD:         rd_data_next = stat_crc_bad;
            ADDR_SEQ_GAPS:        rd_data_next = stat_seq_gaps;
            ADDR_ACCEPTS:         rd_data_next = stat_accepts;
            ADDR_BLOCKS:          rd_data_next = stat_blocks;
            ADDR_RX_PACKETS:      rd_data_next = stat_rx_packets;
            ADDR_RING_BASE_LO:    rd_data_next = ring_base_reg[31:0];
            ADDR_RING_BASE_HI:    rd_data_next = ring_base_reg[63:32];
            ADDR_RING_LEN:        rd_data_next = ring_len_reg;
            ADDR_PROD_IDX:        rd_data_next = {16'b0, ring_prod_idx};
            ADDR_CONS_IDX_SHADOW: rd_data_next = cons_idx_shadow_reg;
            ADDR_MSIX_CFG:        rd_data_next = msix_cfg_reg;
            default:              rd_data_next = 32'hDEADBEEF;
        endcase
    end
    
    // Wait request for multi-cycle accesses
    assign wait_request = (acc_state != ACC_IDLE);
    assign avs_waitrequest = wait_request;

endmodule : csr_avalon
