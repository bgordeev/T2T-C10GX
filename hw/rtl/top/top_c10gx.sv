//-----------------------------------------------------------------------------
// File: top_c10gx.sv
// Description: Top-level integration for T2T tick-to-trade pipeline on
//              Intel Cyclone 10 GX Development Kit.
//
// Clock Domains:
//   - mac_clk:  156.25 MHz (from transceiver)
//   - core_clk: 300 MHz (from PLL)
//   - pcie_clk: 125 MHz (from PCIe Hard IP)
//   - csr_clk:  100 MHz (from PLL)
//
// External Interfaces:
//   - SFP+ transceiver (10G Ethernet)
//   - PCIe Gen2 x4
//   - GPIO output (trigger pulse)
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module top_c10gx (
    //-------------------------------------------------------------------------
    // Clock and Reset Inputs
    //-------------------------------------------------------------------------
    input  logic                    clk_50mhz,        // Board oscillator
    input  logic                    cpu_resetn,       // Active-low reset
    
    //-------------------------------------------------------------------------
    // SFP+ Transceiver Interface
    //-------------------------------------------------------------------------
    input  logic                    sfp_refclk,       // 156.25 MHz reference
    input  logic                    sfp_rx,           // Serial RX
    output logic                    sfp_tx,           // Serial TX
    output logic                    sfp_tx_disable,   // TX disable
    input  logic                    sfp_los,          // Loss of signal
    
    //-------------------------------------------------------------------------
    // PCIe Interface
    //-------------------------------------------------------------------------
    input  logic                    pcie_refclk,      // 100 MHz reference
    input  logic [3:0]              pcie_rx,          // Serial RX lanes
    output logic [3:0]              pcie_tx,          // Serial TX lanes
    input  logic                    pcie_perst_n,     // PCIe reset
    
    //-------------------------------------------------------------------------
    // GPIO
    //-------------------------------------------------------------------------
    output logic                    gpio_pulse,       // Trigger output
    
    //-------------------------------------------------------------------------
    // LED Indicators
    //-------------------------------------------------------------------------
    output logic [3:0]              led               // Status LEDs
);

    //=========================================================================
    // Clock and Reset Generation
    //=========================================================================
    
    logic mac_clk;
    logic core_clk;
    logic pcie_clk;
    logic csr_clk;
    
    logic pll_locked;
    logic mac_rst_n;
    logic core_rst_n;
    logic pcie_rst_n;
    logic csr_rst_n;
    
    // System PLL (generates core_clk and csr_clk from 50 MHz)
    // In actual implementation, this would be Intel PLL IP
    // For now, showing the interface
    
    `ifdef SIMULATION
        // Simulation clock generation
        assign core_clk   = clk_50mhz;  // Simplified for sim
        assign csr_clk    = clk_50mhz;
        assign pll_locked = 1'b1;
    `else
        // PLL instantiation placeholder
        // sys_pll u_sys_pll (
        //     .refclk   (clk_50mhz),
        //     .rst      (~cpu_resetn),
        //     .outclk_0 (core_clk),     // 300 MHz
        //     .outclk_1 (csr_clk),      // 100 MHz
        //     .locked   (pll_locked)
        // );
        assign core_clk   = clk_50mhz;
        assign csr_clk    = clk_50mhz;
        assign pll_locked = 1'b1;
    `endif
    
    // MAC clock comes from transceiver
    assign mac_clk = sfp_refclk;  
    
    // Reset synchronizers for each domain
    cdc_reset_sync u_mac_rst_sync (
        .clk        (mac_clk),
        .async_rst_n(cpu_resetn & pll_locked),
        .sync_rst_n (mac_rst_n)
    );
    
    cdc_reset_sync u_core_rst_sync (
        .clk        (core_clk),
        .async_rst_n(cpu_resetn & pll_locked),
        .sync_rst_n (core_rst_n)
    );
    
    cdc_reset_sync u_csr_rst_sync (
        .clk        (csr_clk),
        .async_rst_n(cpu_resetn & pll_locked),
        .sync_rst_n (csr_rst_n)
    );
    
    //=========================================================================
    // Timestamp Counter (Core Domain)
    //=========================================================================
    
    logic [63:0] timestamp_cnt;
    
    always_ff @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            timestamp_cnt <= '0;
        end else begin
            timestamp_cnt <= timestamp_cnt + 1'b1;
        end
    end
    
    //=========================================================================
    // 10G Ethernet MAC (Placeholder for Intel IP)
    //=========================================================================
    
    // MAC IP signals
    logic [63:0] mac_rx_data;
    logic [7:0]  mac_rx_valid_bytes;
    logic        mac_rx_sop;
    logic        mac_rx_eop;
    logic        mac_rx_valid;
    logic        mac_rx_ready;
    logic        mac_rx_error;
    
    // In real design, instantiate Intel 10G MAC IP here
    // For now, stub connections
    assign mac_rx_data        = '0;
    assign mac_rx_valid_bytes = '0;
    assign mac_rx_sop         = 1'b0;
    assign mac_rx_eop         = 1'b0;
    assign mac_rx_valid       = 1'b0;
    assign mac_rx_error       = 1'b0;
    assign sfp_tx             = 1'b0;
    assign sfp_tx_disable     = 1'b0;
    
    //=========================================================================
    // MAC Wrapper with Ingress Filtering
    //=========================================================================
    
    logic [63:0] mac_axis_tdata;
    logic [7:0]  mac_axis_tkeep;
    logic        mac_axis_tlast;
    logic [71:0] mac_axis_tuser;
    logic        mac_axis_tvalid;
    logic        mac_axis_tready;
    
    // Configuration signals (from CSR, synchronized)
    logic        cfg_enable;
    logic [47:0] cfg_mcast_mac;
    logic        cfg_mcast_enable;
    logic        cfg_promiscuous;
    
    // Statistics
    logic [31:0] stat_rx_packets;
    logic [31:0] stat_rx_bytes;
    logic [31:0] stat_rx_crc_errors;
    logic [31:0] stat_rx_drops;
    
    mac_wrap #(
        .DATA_WIDTH(64),
        .KEEP_WIDTH(8)
    ) u_mac_wrap (
        .mac_clk           (mac_clk),
        .mac_rst_n         (mac_rst_n),
        .core_clk          (core_clk),
        .core_rst_n        (core_rst_n),
        
        // From MAC IP
        .mac_rx_data       (mac_rx_data),
        .mac_rx_valid_bytes(mac_rx_valid_bytes),
        .mac_rx_sop        (mac_rx_sop),
        .mac_rx_eop        (mac_rx_eop),
        .mac_rx_valid      (mac_rx_valid),
        .mac_rx_ready      (mac_rx_ready),
        .mac_rx_error      (mac_rx_error),
        
        // To parser (core domain)
        .m_axis_tdata      (mac_axis_tdata),
        .m_axis_tkeep      (mac_axis_tkeep),
        .m_axis_tlast      (mac_axis_tlast),
        .m_axis_tuser      (mac_axis_tuser),
        .m_axis_tvalid     (mac_axis_tvalid),
        .m_axis_tready     (mac_axis_tready),
        
        .timestamp_cnt     (timestamp_cnt),
        
        .cfg_enable        (cfg_enable),
        .cfg_mcast_mac     (cfg_mcast_mac),
        .cfg_mcast_enable  (cfg_mcast_enable),
        .cfg_promiscuous   (cfg_promiscuous),
        
        .stat_rx_packets   (stat_rx_packets),
        .stat_rx_bytes     (stat_rx_bytes),
        .stat_rx_crc_errors(stat_rx_crc_errors),
        .stat_rx_drops     (stat_rx_drops)
    );
    
    //=========================================================================
    // L2/L3/L4 Parser
    //=========================================================================
    
    logic [63:0]  parser_axis_tdata;
    logic [7:0]   parser_axis_tkeep;
    logic         parser_axis_tlast;
    logic [127:0] parser_axis_tuser;
    logic         parser_axis_tvalid;
    logic         parser_axis_tready;
    
    logic         cfg_check_ip_csum;
    logic [15:0]  cfg_expected_port;
    
    logic [31:0]  stat_parsed_packets;
    logic [31:0]  stat_ip_errors;
    logic [31:0]  stat_udp_errors;
    logic [31:0]  stat_length_errors;
    
    l2l3l4_parser #(
        .DATA_WIDTH(64),
        .KEEP_WIDTH(8)
    ) u_parser (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        
        .s_axis_tdata     (mac_axis_tdata),
        .s_axis_tkeep     (mac_axis_tkeep),
        .s_axis_tlast     (mac_axis_tlast),
        .s_axis_tuser     (mac_axis_tuser),
        .s_axis_tvalid    (mac_axis_tvalid),
        .s_axis_tready    (mac_axis_tready),
        
        .m_axis_tdata     (parser_axis_tdata),
        .m_axis_tkeep     (parser_axis_tkeep),
        .m_axis_tlast     (parser_axis_tlast),
        .m_axis_tuser     (parser_axis_tuser),
        .m_axis_tvalid    (parser_axis_tvalid),
        .m_axis_tready    (parser_axis_tready),
        
        .cfg_check_ip_csum(cfg_check_ip_csum),
        .cfg_expected_port(cfg_expected_port),
        
        .stat_parsed_packets(stat_parsed_packets),
        .stat_ip_errors     (stat_ip_errors),
        .stat_udp_errors    (stat_udp_errors),
        .stat_length_errors (stat_length_errors)
    );
    
    //=========================================================================
    // ITCH Splitter
    //=========================================================================
    
    logic [511:0] splitter_axis_tdata;
    logic [7:0]   splitter_axis_tkeep;
    logic         splitter_axis_tlast;
    logic [95:0]  splitter_axis_tuser;
    logic         splitter_axis_tvalid;
    logic         splitter_axis_tready;
    
    logic [31:0]  cfg_expected_seq;
    logic         cfg_seq_check_en;
    
    logic [31:0]  stat_messages;
    logic [31:0]  stat_seq_gaps;
    logic [31:0]  stat_seq_dupes;
    logic         status_stale;
    
    itch_splitter #(
        .DATA_WIDTH    (64),
        .KEEP_WIDTH    (8),
        .MAX_MSG_BYTES (64),
        .MSG_BUF_DEPTH (128)
    ) u_splitter (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        
        .s_axis_tdata     (parser_axis_tdata),
        .s_axis_tkeep     (parser_axis_tkeep),
        .s_axis_tlast     (parser_axis_tlast),
        .s_axis_tuser     (parser_axis_tuser),
        .s_axis_tvalid    (parser_axis_tvalid),
        .s_axis_tready    (parser_axis_tready),
        
        .m_axis_tdata     (splitter_axis_tdata),
        .m_axis_tkeep     (splitter_axis_tkeep),
        .m_axis_tlast     (splitter_axis_tlast),
        .m_axis_tuser     (splitter_axis_tuser),
        .m_axis_tvalid    (splitter_axis_tvalid),
        .m_axis_tready    (splitter_axis_tready),
        
        .cfg_expected_seq (cfg_expected_seq),
        .cfg_seq_check_en (cfg_seq_check_en),
        
        .stat_messages    (stat_messages),
        .stat_seq_gaps    (stat_seq_gaps),
        .stat_seq_dupes   (stat_seq_dupes),
        .status_stale     (status_stale)
    );
    
    //=========================================================================
    // ITCH Decoder
    //=========================================================================
    
    itch_msg_t    decoded_msg;
    logic         decoded_valid;
    logic         decoded_ready;
    
    // Symbol lookup interface
    logic [63:0]  sym_lookup_key;
    logic         sym_lookup_valid;
    logic [9:0]   sym_lookup_idx;
    logic         sym_lookup_hit;
    logic         sym_lookup_ready;
    
    logic [31:0]  stat_add_orders;
    logic [31:0]  stat_executes;
    logic [31:0]  stat_cancels;
    logic [31:0]  stat_deletes;
    logic [31:0]  stat_replaces;
    logic [31:0]  stat_trades;
    logic [31:0]  stat_unknown;
    
    itch_decoder #(
        .MAX_MSG_BYTES(64)
    ) u_decoder (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        
        .s_axis_tdata     (splitter_axis_tdata),
        .s_axis_tkeep     (splitter_axis_tkeep),
        .s_axis_tlast     (splitter_axis_tlast),
        .s_axis_tuser     (splitter_axis_tuser),
        .s_axis_tvalid    (splitter_axis_tvalid),
        .s_axis_tready    (splitter_axis_tready),
        
        .decoded_msg      (decoded_msg),
        .decoded_valid    (decoded_valid),
        .decoded_ready    (decoded_ready),
        
        .sym_lookup_key   (sym_lookup_key),
        .sym_lookup_valid (sym_lookup_valid),
        .sym_lookup_idx   (sym_lookup_idx),
        .sym_lookup_hit   (sym_lookup_hit),
        .sym_lookup_ready (sym_lookup_ready),
        
        .stat_add_orders  (stat_add_orders),
        .stat_executes    (stat_executes),
        .stat_cancels     (stat_cancels),
        .stat_deletes     (stat_deletes),
        .stat_replaces    (stat_replaces),
        .stat_trades      (stat_trades),
        .stat_unknown     (stat_unknown)
    );
    
    //=========================================================================
    // Symbol Table CAM
    //=========================================================================
    
    // CSR interface for symbol table
    logic [63:0]  symtab_key;
    logic [9:0]   symtab_idx;
    logic         symtab_write;
    logic         symtab_commit;
    logic         symtab_ready;
    logic [10:0]  symtab_num_entries;
    logic         symtab_full;
    
    symtab_cam #(
        .NUM_ENTRIES(1024),
        .KEY_WIDTH  (64),
        .IDX_WIDTH  (10)
    ) u_symtab (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        
        // Lookup interface (from decoder)
        .lookup_key       (sym_lookup_key),
        .lookup_valid     (sym_lookup_valid),
        .lookup_idx       (sym_lookup_idx),
        .lookup_hit       (sym_lookup_hit),
        .lookup_ready     (sym_lookup_ready),
        
        // CSR load interface
        .load_key         (symtab_key),
        .load_idx         (symtab_idx),
        .load_valid       (symtab_write),
        .load_ready       (symtab_ready),
        .commit           (symtab_commit),
        .commit_done      (),
        
        .num_entries_loaded(symtab_num_entries),
        .table_full       (symtab_full)
    );
    
    //=========================================================================
    // Top-of-Book Builder
    //=========================================================================
    
    book_event_t  book_event;
    logic         book_event_valid;
    logic         book_event_ready;
    
    logic [31:0]  stat_book_updates;
    logic [31:0]  stat_bank_conflicts;
    logic [31:0]  stat_invalid_symbols;
    
    book_tob #(
        .NUM_SYMBOLS(1024),
        .NUM_BANKS  (4),
        .IDX_WIDTH  (10)
    ) u_book (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        
        .msg_in           (decoded_msg),
        .msg_valid        (decoded_valid),
        .msg_ready        (decoded_ready),
        
        .event_out        (book_event),
        .event_valid      (book_event_valid),
        .event_ready      (book_event_ready),
        
        .cfg_enable       (cfg_enable),
        
        .stat_updates     (stat_book_updates),
        .stat_bank_conflicts(stat_bank_conflicts),
        .stat_invalid_symbols(stat_invalid_symbols)
    );
    
    //=========================================================================
    // Risk Gate
    //=========================================================================
    
    risk_output_t risk_decision;
    logic         risk_decision_valid;
    logic         risk_decision_ready;
    
    // Risk configuration
    logic [15:0]  cfg_price_band_bps;
    logic [15:0]  cfg_token_rate;
    logic [15:0]  cfg_token_max;
    logic signed [31:0] cfg_position_limit;
    logic [31:0]  cfg_stale_usec;
    logic [15:0]  cfg_seq_gap_thr;
    logic         cfg_kill;
    logic         cfg_gpio_enable;
    
    // Reference price (simplified - would be per-symbol in full impl)
    logic [9:0]   ref_price_addr;
    logic         ref_price_rd;
    logic [31:0]  ref_price_data;
    logic         ref_price_valid;
    
    // Stub reference price (would connect to reference price table)
    assign ref_price_data  = 32'd10000;  // $100.00 reference
    assign ref_price_valid = ref_price_rd;
    
    // Audit FIFO
    logic [63:0]  audit_data;
    logic         audit_valid;
    logic         audit_ready;
    
    logic [31:0]  stat_accepts;
    logic [31:0]  stat_rejects;
    logic [31:0]  stat_price_band_fails;
    logic [31:0]  stat_token_fails;
    logic [31:0]  stat_position_fails;
    logic [31:0]  stat_kill_blocks;
    logic [31:0]  stat_stale_blocks;
    
    risk_gate u_risk_gate (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        
        .event_in         (book_event),
        .event_valid      (book_event_valid),
        .event_ready      (book_event_ready),
        
        .decision_out     (risk_decision),
        .decision_valid   (risk_decision_valid),
        .decision_ready   (risk_decision_ready),
        
        .timestamp_cnt    (timestamp_cnt),
        
        .cfg_enable       (cfg_enable),
        .cfg_price_band_bps(cfg_price_band_bps),
        .cfg_token_rate   (cfg_token_rate),
        .cfg_token_max    (16'd10000),
        .cfg_position_limit(cfg_position_limit),
        .cfg_stale_usec   (cfg_stale_usec),
        .cfg_seq_gap_thr  (cfg_seq_gap_thr),
        .cfg_kill         (cfg_kill),
        .cfg_gpio_enable  (cfg_gpio_enable),
        
        .ref_price_addr   (ref_price_addr),
        .ref_price_rd     (ref_price_rd),
        .ref_price_data   (ref_price_data),
        .ref_price_valid  (ref_price_valid),
        
        .gpio_pulse       (gpio_pulse),
        
        .audit_data       (audit_data),
        .audit_valid      (audit_valid),
        .audit_ready      (audit_ready),
        
        .stat_accepts     (stat_accepts),
        .stat_rejects     (stat_rejects),
        .stat_price_band_fails(stat_price_band_fails),
        .stat_token_fails (stat_token_fails),
        .stat_position_fails(stat_position_fails),
        .stat_kill_blocks (stat_kill_blocks),
        .stat_stale_blocks(stat_stale_blocks)
    );
    
    // Stub audit ready (would connect to FIFO)
    assign audit_ready = 1'b1;
    
    //=========================================================================
    // PCIe DMA (Stub - would instantiate Intel PCIe Hard IP)
    //=========================================================================
    
    // PCIe clock from Hard IP
    assign pcie_clk = pcie_refclk;  // Simplified
    
    cdc_reset_sync u_pcie_rst_sync (
        .clk        (pcie_clk),
        .async_rst_n(cpu_resetn & pcie_perst_n),
        .sync_rst_n (pcie_rst_n)
    );
    
    // Ring buffer configuration (from CSR)
    logic [63:0]  ring_base_addr;
    logic [15:0]  ring_length;
    logic [15:0]  ring_cons_idx_shadow;
    logic [15:0]  ring_prod_idx;
    logic         ring_full;
    logic         ring_overflow;
    
    // PCIe stub signals
    assign pcie_tx = '0;
    assign ring_prod_idx = '0;
    assign ring_full = 1'b0;
    assign ring_overflow = 1'b0;
    assign risk_decision_ready = 1'b1;
    
    //=========================================================================
    // CSR Block (CSR Clock Domain)
    //=========================================================================
    
    // Avalon-MM slave interface (from PCIe-to-Avalon bridge)
    logic [11:0]  avs_address;
    logic         avs_read;
    logic         avs_write;
    logic [31:0]  avs_writedata;
    logic [3:0]   avs_byteenable;
    logic [31:0]  avs_readdata;
    logic         avs_readdatavalid;
    logic         avs_waitrequest;
    
    // Stub Avalon interface (would come from PCIe bridge)
    assign avs_address    = '0;
    assign avs_read       = 1'b0;
    assign avs_write      = 1'b0;
    assign avs_writedata  = '0;
    assign avs_byteenable = 4'hF;
    
    // Default configuration (would come from CSR)
    assign cfg_enable         = 1'b1;
    assign cfg_mcast_mac      = 48'h01_00_5E_00_00_01;
    assign cfg_mcast_enable   = 1'b1;
    assign cfg_promiscuous    = 1'b0;
    assign cfg_check_ip_csum  = 1'b0;
    assign cfg_expected_port  = 16'd26400;  // Typical ITCH port
    assign cfg_expected_seq   = 32'd1;
    assign cfg_seq_check_en   = 1'b1;
    assign cfg_price_band_bps = 16'd500;
    assign cfg_token_rate     = 16'd1000;
    assign cfg_position_limit = 32'd1000000;
    assign cfg_stale_usec     = 32'd100000;
    assign cfg_seq_gap_thr    = 16'd100;
    assign cfg_kill           = 1'b0;
    assign cfg_gpio_enable    = 1'b1;
    assign ring_base_addr     = 64'h0;
    assign ring_length        = 16'd65536;
    assign ring_cons_idx_shadow = 16'd0;
    assign symtab_key         = 64'h0;
    assign symtab_idx         = 10'd0;
    assign symtab_write       = 1'b0;
    assign symtab_commit      = 1'b0;
    
    //=========================================================================
    // LED Status Indicators
    //=========================================================================
    
    // Heartbeat counter
    logic [25:0] heartbeat_cnt;
    
    always_ff @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            heartbeat_cnt <= '0;
        end else begin
            heartbeat_cnt <= heartbeat_cnt + 1'b1;
        end
    end
    
    assign led[0] = heartbeat_cnt[25];      // Heartbeat
    assign led[1] = cfg_enable;             // Pipeline enabled
    assign led[2] = !sfp_los;               // SFP link present
    assign led[3] = status_stale;           // Stale data indicator

endmodule : top_c10gx
