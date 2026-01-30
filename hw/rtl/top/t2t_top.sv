//-----------------------------------------------------------------------------
// File: t2t_top.sv
// Description: Top-level integration for the T2T-C10GX tick-to-trade pipeline.
//              Instantiates all major blocks and handles clock domain crossing.
//
// Clock Domains:
//   - mac_clk:  156.25 MHz (from transceiver)
//   - core_clk: 300 MHz (main processing)
//   - pcie_clk: 125 MHz (PCIe endpoint)
//   - csr_clk:  100 MHz (control/status)
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module t2t_top (
    //-------------------------------------------------------------------------
    // System Clocks and Resets
    //-------------------------------------------------------------------------
    input  logic                    refclk_156p25,   // SFP+ reference clock
    input  logic                    refclk_100,      // Reference for PLLs
    input  logic                    pcie_refclk,     // PCIe reference clock
    input  logic                    rst_n,           // Async reset (active low)
    
    //-------------------------------------------------------------------------
    // 10G Ethernet Transceiver Interface
    //-------------------------------------------------------------------------
    input  logic                    sfp_rx_p,
    input  logic                    sfp_rx_n,
    output logic                    sfp_tx_p,
    output logic                    sfp_tx_n,
    
    // SFP+ control
    output logic                    sfp_tx_disable,
    input  logic                    sfp_los,
    input  logic                    sfp_mod_det,
    
    //-------------------------------------------------------------------------
    // PCIe Interface (directly to Hard IP pins)
    //-------------------------------------------------------------------------
    input  logic [3:0]              pcie_rx_p,
    input  logic [3:0]              pcie_rx_n,
    output logic [3:0]              pcie_tx_p,
    output logic [3:0]              pcie_tx_n,
    input  logic                    pcie_perst_n,
    
    //-------------------------------------------------------------------------
    // GPIO
    //-------------------------------------------------------------------------
    output logic                    gpio_latency_pulse,
    output logic [7:0]              gpio_status_led,
    
    //-------------------------------------------------------------------------
    // Debug (optional)
    //-------------------------------------------------------------------------
    output logic                    debug_heartbeat
);

    //=========================================================================
    // Internal Clock and Reset
    //=========================================================================
    
    logic mac_clk;
    logic core_clk;
    logic pcie_clk;
    logic csr_clk;
    
    logic mac_rst_n;
    logic core_rst_n;
    logic pcie_rst_n;
    logic csr_rst_n;
    
    //=========================================================================
    // Internal Signals
    //=========================================================================
    
    // MAC to Parser (core_clk domain)
    logic [63:0]  mac_to_parser_tdata;
    logic [7:0]   mac_to_parser_tkeep;
    logic         mac_to_parser_tlast;
    logic [71:0]  mac_to_parser_tuser;
    logic         mac_to_parser_tvalid;
    logic         mac_to_parser_tready;
    
    // Parser to ITCH Splitter
    logic [63:0]  parser_to_splitter_tdata;
    logic [7:0]   parser_to_splitter_tkeep;
    logic         parser_to_splitter_tlast;
    logic [127:0] parser_to_splitter_tuser;
    logic         parser_to_splitter_tvalid;
    logic         parser_to_splitter_tready;
    
    // ITCH Splitter to Decoder
    logic [511:0] splitter_to_decoder_tdata;
    logic [7:0]   splitter_to_decoder_tkeep;
    logic         splitter_to_decoder_tlast;
    logic [95:0]  splitter_to_decoder_tuser;
    logic         splitter_to_decoder_tvalid;
    logic         splitter_to_decoder_tready;
    
    // Decoder to Book
    itch_msg_t    decoder_to_book_msg;
    logic         decoder_to_book_valid;
    logic         decoder_to_book_ready;
    
    // Book to Risk
    book_event_t  book_to_risk_event;
    logic         book_to_risk_valid;
    logic         book_to_risk_ready;
    
    // Risk to DMA
    risk_output_t risk_to_dma_output;
    logic         risk_to_dma_valid;
    logic         risk_to_dma_ready;
    
    // Symbol lookup interface
    logic [63:0]  sym_lookup_key;
    logic         sym_lookup_valid;
    logic [9:0]   sym_lookup_idx;
    logic         sym_lookup_hit;
    logic         sym_lookup_ready;
    
    // Timestamp
    logic [63:0]  timestamp_cnt;
    
    // Configuration signals (from CSR)
    logic         cfg_enable;
    logic         cfg_promiscuous;
    logic [47:0]  cfg_mcast_mac;
    logic         cfg_mcast_enable;
    logic         cfg_check_ip_csum;
    logic [15:0]  cfg_expected_port;
    logic [15:0]  cfg_price_band_bps;
    logic [15:0]  cfg_token_rate;
    logic [15:0]  cfg_token_max;
    logic signed [31:0] cfg_position_limit;
    logic [31:0]  cfg_stale_cycles;
    logic         cfg_kill_switch;
    logic [31:0]  cfg_expected_seq;
    logic         cfg_seq_check_en;
    logic [63:0]  cfg_ring_base;
    logic [15:0]  cfg_ring_size;
    logic         cfg_msix_enable;
    logic [15:0]  cfg_msix_threshold;
    
    // Symbol table interface
    logic [63:0]  symtab_key;
    logic [9:0]   symtab_idx;
    logic         symtab_load;
    logic         symtab_commit;
    
    // Reference price interface
    logic [9:0]   ref_price_addr;
    logic [31:0]  ref_price_data;
    logic         ref_price_we;
    
    // Status signals
    logic [15:0]  status_prod_idx;
    logic [15:0]  status_cons_idx;
    logic         status_ring_full;
    logic         status_ring_empty;
    logic         status_stale;
    
    // Statistics
    logic [31:0]  stat_rx_packets;
    logic [31:0]  stat_rx_bytes;
    logic [31:0]  stat_rx_crc_errors;
    logic [31:0]  stat_rx_drops;
    logic [31:0]  stat_parsed_packets;
    logic [31:0]  stat_messages;
    logic [31:0]  stat_seq_gaps;
    logic [31:0]  stat_book_updates;
    logic [31:0]  stat_bank_conflicts;
    logic [31:0]  stat_risk_accepts;
    logic [31:0]  stat_risk_rejects;
    logic [31:0]  stat_dma_records;
    logic [31:0]  stat_dma_drops;
    
    // Latency histogram
    logic [31:0]  lat_hist_data;
    logic [7:0]   lat_hist_addr;
    logic         lat_hist_rd;
    
    // PCIe interface
    logic [63:0]  pcie_address;
    logic [255:0] pcie_writedata;
    logic [31:0]  pcie_byteenable;
    logic         pcie_write;
    logic         pcie_read;
    logic [255:0] pcie_readdata;
    logic         pcie_waitrequest;
    logic         pcie_readdatavalid;
    
    // MSI-X
    logic         msix_irq;
    logic [4:0]   msix_vector;
    logic         msix_ack;
    
    // CSR Avalon-MM
    logic [11:0]  csr_address;
    logic [31:0]  csr_writedata;
    logic [3:0]   csr_byteenable;
    logic         csr_write;
    logic         csr_read;
    logic [31:0]  csr_readdata;
    logic         csr_waitrequest;
    logic         csr_readdatavalid;
    
    // MAC signals (directly from 10G MAC IP)
    logic [63:0]  mac_rx_data;
    logic [7:0]   mac_rx_valid_bytes;
    logic         mac_rx_sop;
    logic         mac_rx_eop;
    logic         mac_rx_valid;
    logic         mac_rx_ready;
    logic         mac_rx_error;
    
    //=========================================================================
    // PLL and Reset Generation
    //=========================================================================
    
    // Core PLL: 100 MHz -> 300 MHz
    pll_core u_pll_core (
        .refclk   (refclk_100),
        .rst      (~rst_n),
        .outclk_0 (core_clk),    // 300 MHz
        .outclk_1 (csr_clk),     // 100 MHz
        .locked   ()
    );
    
    // MAC clock from transceiver
    assign mac_clk = refclk_156p25;
    
    // Reset synchronizers
    cdc_reset_sync u_rst_mac (
        .clk         (mac_clk),
        .async_rst_n (rst_n),
        .sync_rst_n  (mac_rst_n)
    );
    
    cdc_reset_sync u_rst_core (
        .clk         (core_clk),
        .async_rst_n (rst_n),
        .sync_rst_n  (core_rst_n)
    );
    
    cdc_reset_sync u_rst_pcie (
        .clk         (pcie_clk),
        .async_rst_n (rst_n && pcie_perst_n),
        .sync_rst_n  (pcie_rst_n)
    );
    
    cdc_reset_sync u_rst_csr (
        .clk         (csr_clk),
        .async_rst_n (rst_n),
        .sync_rst_n  (csr_rst_n)
    );
    
    //=========================================================================
    // Timestamp Counter
    //=========================================================================
    
    timestamp_counter u_timestamp (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        .timestamp        (timestamp_cnt),
        .latency_start    (book_to_risk_event.ingress_ts),
        .latency_end      (risk_to_dma_output.decision_ts),
        .latency_valid    (risk_to_dma_valid && risk_to_dma_ready),
        .hist_addr        (lat_hist_addr),
        .hist_rd          (lat_hist_rd),
        .hist_data        (lat_hist_data),
        .cfg_enable       (cfg_enable),
        .cfg_hist_clear   (1'b0),
        .stat_samples     (),
        .stat_overflow    (),
        .stat_min_latency (),
        .stat_max_latency (),
        .stat_sum_latency ()
    );
    
    //=========================================================================
    // 10G Ethernet MAC Wrapper
    //=========================================================================
    
    // Note: In actual implementation, instantiate Intel 10G MAC IP here
    // mac_wrap connects to the MAC IP and provides AXI-Stream output
    
    mac_wrap u_mac_wrap (
        .mac_clk          (mac_clk),
        .mac_rst_n        (mac_rst_n),
        .core_clk         (core_clk),
        .core_rst_n       (core_rst_n),
        
        // From MAC IP
        .mac_rx_data      (mac_rx_data),
        .mac_rx_valid_bytes (mac_rx_valid_bytes),
        .mac_rx_sop       (mac_rx_sop),
        .mac_rx_eop       (mac_rx_eop),
        .mac_rx_valid     (mac_rx_valid),
        .mac_rx_ready     (mac_rx_ready),
        .mac_rx_error     (mac_rx_error),
        
        // AXI-Stream output (core_clk domain)
        .m_axis_tdata     (mac_to_parser_tdata),
        .m_axis_tkeep     (mac_to_parser_tkeep),
        .m_axis_tlast     (mac_to_parser_tlast),
        .m_axis_tuser     (mac_to_parser_tuser),
        .m_axis_tvalid    (mac_to_parser_tvalid),
        .m_axis_tready    (mac_to_parser_tready),
        
        .timestamp_cnt    (timestamp_cnt),
        
        .cfg_enable       (cfg_enable),
        .cfg_mcast_mac    (cfg_mcast_mac),
        .cfg_mcast_enable (cfg_mcast_enable),
        .cfg_promiscuous  (cfg_promiscuous),
        
        .stat_rx_packets  (stat_rx_packets),
        .stat_rx_bytes    (stat_rx_bytes),
        .stat_rx_crc_errors (stat_rx_crc_errors),
        .stat_rx_drops    (stat_rx_drops)
    );
    
    //=========================================================================
    // L2/L3/L4 Parser
    //=========================================================================
    
    l2l3l4_parser u_parser (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        
        .s_axis_tdata     (mac_to_parser_tdata),
        .s_axis_tkeep     (mac_to_parser_tkeep),
        .s_axis_tlast     (mac_to_parser_tlast),
        .s_axis_tuser     (mac_to_parser_tuser),
        .s_axis_tvalid    (mac_to_parser_tvalid),
        .s_axis_tready    (mac_to_parser_tready),
        
        .m_axis_tdata     (parser_to_splitter_tdata),
        .m_axis_tkeep     (parser_to_splitter_tkeep),
        .m_axis_tlast     (parser_to_splitter_tlast),
        .m_axis_tuser     (parser_to_splitter_tuser),
        .m_axis_tvalid    (parser_to_splitter_tvalid),
        .m_axis_tready    (parser_to_splitter_tready),
        
        .cfg_check_ip_csum (cfg_check_ip_csum),
        .cfg_expected_port (cfg_expected_port),
        
        .stat_parsed_packets (stat_parsed_packets),
        .stat_ip_errors   (),
        .stat_udp_errors  (),
        .stat_length_errors ()
    );
    
    //=========================================================================
    // ITCH Splitter
    //=========================================================================
    
    itch_splitter u_splitter (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        
        .s_axis_tdata     (parser_to_splitter_tdata),
        .s_axis_tkeep     (parser_to_splitter_tkeep),
        .s_axis_tlast     (parser_to_splitter_tlast),
        .s_axis_tuser     (parser_to_splitter_tuser),
        .s_axis_tvalid    (parser_to_splitter_tvalid),
        .s_axis_tready    (parser_to_splitter_tready),
        
        .m_axis_tdata     (splitter_to_decoder_tdata),
        .m_axis_tkeep     (splitter_to_decoder_tkeep),
        .m_axis_tlast     (splitter_to_decoder_tlast),
        .m_axis_tuser     (splitter_to_decoder_tuser),
        .m_axis_tvalid    (splitter_to_decoder_tvalid),
        .m_axis_tready    (splitter_to_decoder_tready),
        
        .cfg_expected_seq (cfg_expected_seq),
        .cfg_seq_check_en (cfg_seq_check_en),
        
        .stat_messages    (stat_messages),
        .stat_seq_gaps    (stat_seq_gaps),
        .stat_seq_dupes   (),
        .status_stale     (status_stale)
    );
    
    //=========================================================================
    // ITCH Decoder
    //=========================================================================
    
    itch_decoder u_decoder (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        
        .s_axis_tdata     (splitter_to_decoder_tdata),
        .s_axis_tkeep     (splitter_to_decoder_tkeep),
        .s_axis_tlast     (splitter_to_decoder_tlast),
        .s_axis_tuser     (splitter_to_decoder_tuser),
        .s_axis_tvalid    (splitter_to_decoder_tvalid),
        .s_axis_tready    (splitter_to_decoder_tready),
        
        .decoded_msg      (decoder_to_book_msg),
        .decoded_valid    (decoder_to_book_valid),
        .decoded_ready    (decoder_to_book_ready),
        
        .sym_lookup_key   (sym_lookup_key),
        .sym_lookup_valid (sym_lookup_valid),
        .sym_lookup_idx   (sym_lookup_idx),
        .sym_lookup_hit   (sym_lookup_hit),
        .sym_lookup_ready (sym_lookup_ready),
        
        .stat_add_orders  (),
        .stat_executes    (),
        .stat_cancels     (),
        .stat_deletes     (),
        .stat_replaces    (),
        .stat_trades      (),
        .stat_unknown     ()
    );
    
    //=========================================================================
    // Symbol Table CAM
    //=========================================================================
    
    symtab_cam u_symtab (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        
        .lookup_key       (sym_lookup_key),
        .lookup_valid     (sym_lookup_valid),
        .lookup_idx       (sym_lookup_idx),
        .lookup_hit       (sym_lookup_hit),
        .lookup_ready     (sym_lookup_ready),
        
        .load_key         (symtab_key),
        .load_idx         (symtab_idx),
        .load_valid       (symtab_load),
        .load_ready       (),
        
        .commit           (symtab_commit),
        .commit_done      (),
        
        .num_entries_loaded (),
        .table_full       ()
    );
    
    //=========================================================================
    // Top-of-Book Builder
    //=========================================================================
    
    book_tob u_book (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        
        .msg_in           (decoder_to_book_msg),
        .msg_valid        (decoder_to_book_valid),
        .msg_ready        (decoder_to_book_ready),
        
        .event_out        (book_to_risk_event),
        .event_valid      (book_to_risk_valid),
        .event_ready      (book_to_risk_ready),
        
        .cfg_enable       (cfg_enable),
        
        .stat_updates     (stat_book_updates),
        .stat_bank_conflicts (stat_bank_conflicts),
        .stat_invalid_symbols ()
    );
    
    //=========================================================================
    // Risk Gate
    //=========================================================================
    
    risk_gate u_risk (
        .clk              (core_clk),
        .rst_n            (core_rst_n),
        
        .event_in         (book_to_risk_event),
        .event_valid      (book_to_risk_valid),
        .event_ready      (book_to_risk_ready),
        
        .risk_out         (risk_to_dma_output),
        .risk_valid       (risk_to_dma_valid),
        .risk_ready       (risk_to_dma_ready),
        
        .gpio_pulse       (gpio_latency_pulse),
        
        .cfg_price_band_bps (cfg_price_band_bps),
        .cfg_token_rate   (cfg_token_rate),
        .cfg_token_max    (cfg_token_max),
        .cfg_position_limit (cfg_position_limit),
        .cfg_stale_cycles (cfg_stale_cycles),
        .cfg_kill_switch  (cfg_kill_switch),
        .cfg_enable       (cfg_enable),
        
        .ref_price_addr   (ref_price_addr),
        .ref_price_data   (ref_price_data),
        .ref_price_we     (ref_price_we),
        
        .current_ts       (timestamp_cnt),
        
        .stat_accepts     (stat_risk_accepts),
        .stat_rejects     (stat_risk_rejects),
        .stat_price_band_fails (),
        .stat_token_fails (),
        .stat_position_fails (),
        .stat_stale_fails (),
        .stat_kill_blocks ()
    );
    
    //=========================================================================
    // PCIe DMA Engine
    //=========================================================================
    
    // CDC FIFO from core_clk to pcie_clk
    // (Simplified - in practice, use proper CDC FIFO)
    
    pcie_dma u_dma (
        .clk              (pcie_clk),
        .rst_n            (pcie_rst_n),
        
        .record_in        (risk_to_dma_output),
        .record_valid     (risk_to_dma_valid),
        .record_ready     (risk_to_dma_ready),
        
        .pcie_address     (pcie_address),
        .pcie_writedata   (pcie_writedata),
        .pcie_byteenable  (pcie_byteenable),
        .pcie_write       (pcie_write),
        .pcie_read        (pcie_read),
        .pcie_readdata    (pcie_readdata),
        .pcie_waitrequest (pcie_waitrequest),
        .pcie_readdatavalid (pcie_readdatavalid),
        
        .msix_irq         (msix_irq),
        .msix_vector      (msix_vector),
        .msix_ack         (msix_ack),
        
        .cfg_ring_base    (cfg_ring_base),
        .cfg_ring_size    (cfg_ring_size),
        .cfg_enable       (cfg_enable),
        .cfg_msix_enable  (cfg_msix_enable),
        .cfg_msix_threshold (cfg_msix_threshold),
        
        .status_prod_idx  (status_prod_idx),
        .status_cons_idx  (status_cons_idx),
        .status_full      (status_ring_full),
        .status_empty     (status_ring_empty),
        
        .stat_records_dma (stat_dma_records),
        .stat_drops       (stat_dma_drops),
        .stat_irqs        ()
    );
    
    //=========================================================================
    // CSR Block
    //=========================================================================
    
    csr_block u_csr (
        .clk              (csr_clk),
        .rst_n            (csr_rst_n),
        
        .avmm_address     (csr_address),
        .avmm_writedata   (csr_writedata),
        .avmm_byteenable  (csr_byteenable),
        .avmm_write       (csr_write),
        .avmm_read        (csr_read),
        .avmm_readdata    (csr_readdata),
        .avmm_waitrequest (csr_waitrequest),
        .avmm_readdatavalid (csr_readdatavalid),
        
        .cfg_enable       (cfg_enable),
        .cfg_promiscuous  (cfg_promiscuous),
        .cfg_mcast_mac    (cfg_mcast_mac),
        .cfg_mcast_enable (cfg_mcast_enable),
        .cfg_check_ip_csum (cfg_check_ip_csum),
        .cfg_expected_port (cfg_expected_port),
        .cfg_price_band_bps (cfg_price_band_bps),
        .cfg_token_rate   (cfg_token_rate),
        .cfg_token_max    (cfg_token_max),
        .cfg_position_limit (cfg_position_limit),
        .cfg_stale_cycles (cfg_stale_cycles),
        .cfg_kill_switch  (cfg_kill_switch),
        .cfg_expected_seq (cfg_expected_seq),
        .cfg_seq_check_en (cfg_seq_check_en),
        .cfg_ring_base    (cfg_ring_base),
        .cfg_ring_size    (cfg_ring_size),
        .cfg_msix_enable  (cfg_msix_enable),
        .cfg_msix_threshold (cfg_msix_threshold),
        
        .symtab_key       (symtab_key),
        .symtab_idx       (symtab_idx),
        .symtab_load      (symtab_load),
        .symtab_commit    (symtab_commit),
        
        .ref_price_addr   (ref_price_addr),
        .ref_price_data   (ref_price_data),
        .ref_price_we     (ref_price_we),
        
        .status_prod_idx  (status_prod_idx),
        .status_cons_idx  (status_cons_idx),
        .status_ring_full (status_ring_full),
        .status_ring_empty (status_ring_empty),
        .status_stale     (status_stale),
        
        .stat_rx_packets  (stat_rx_packets),
        .stat_rx_bytes    (stat_rx_bytes),
        .stat_rx_crc_errors (stat_rx_crc_errors),
        .stat_rx_drops    (stat_rx_drops),
        .stat_parsed_packets (stat_parsed_packets),
        .stat_messages    (stat_messages),
        .stat_seq_gaps    (stat_seq_gaps),
        .stat_book_updates (stat_book_updates),
        .stat_bank_conflicts (stat_bank_conflicts),
        .stat_risk_accepts (stat_risk_accepts),
        .stat_risk_rejects (stat_risk_rejects),
        .stat_dma_records (stat_dma_records),
        .stat_dma_drops   (stat_dma_drops),
        
        .lat_hist_data    (lat_hist_data),
        .lat_hist_addr    (lat_hist_addr),
        .lat_hist_rd      (lat_hist_rd),
        
        .build_timestamp  (32'h6798_1234),  // Example timestamp
        .build_git_hash   (32'hABCD_EF01)   // Example hash
    );
    
    //=========================================================================
    // Status LEDs
    //=========================================================================
    
    assign gpio_status_led[0] = cfg_enable;
    assign gpio_status_led[1] = !status_ring_empty;
    assign gpio_status_led[2] = status_ring_full;
    assign gpio_status_led[3] = status_stale;
    assign gpio_status_led[4] = cfg_kill_switch;
    assign gpio_status_led[5] = mac_rst_n;
    assign gpio_status_led[6] = pcie_rst_n;
    assign gpio_status_led[7] = debug_heartbeat;
    
    // Heartbeat (toggle every ~1 second at 300 MHz)
    logic [27:0] heartbeat_cnt;
    always_ff @(posedge core_clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            heartbeat_cnt   <= '0;
            debug_heartbeat <= 1'b0;
        end else begin
            heartbeat_cnt <= heartbeat_cnt + 1'b1;
            if (heartbeat_cnt == 28'd150_000_000) begin
                heartbeat_cnt   <= '0;
                debug_heartbeat <= ~debug_heartbeat;
            end
        end
    end
    
    //=========================================================================
    // SFP+ Control
    //=========================================================================
    
    assign sfp_tx_disable = 1'b0;  // Enable TX
    
    //=========================================================================
    // Placeholder Instantiations
    //=========================================================================
    
    // Intel 10G MAC IP would be instantiated here
    // Intel PCIe Hard IP would be instantiated here
    // PLL IP would be instantiated here
    
    // For now, tie off unused signals
    assign mac_rx_data        = '0;
    assign mac_rx_valid_bytes = '0;
    assign mac_rx_sop         = 1'b0;
    assign mac_rx_eop         = 1'b0;
    assign mac_rx_valid       = 1'b0;
    assign mac_rx_error       = 1'b0;
    
    assign pcie_readdata      = '0;
    assign pcie_waitrequest   = 1'b0;
    assign pcie_readdatavalid = 1'b0;
    assign pcie_clk           = refclk_100;
    assign msix_ack           = 1'b0;
    
    assign csr_address        = '0;
    assign csr_writedata      = '0;
    assign csr_byteenable     = '0;
    assign csr_write          = 1'b0;
    assign csr_read           = 1'b0;

endmodule : t2t_top


//=============================================================================
// Placeholder PLL Module
//=============================================================================
module pll_core (
    input  logic refclk,
    input  logic rst,
    output logic outclk_0,
    output logic outclk_1,
    output logic locked
);
    // Placeholder - would use Intel FPGA PLL IP
    assign outclk_0 = refclk;
    assign outclk_1 = refclk;
    assign locked   = ~rst;
endmodule
