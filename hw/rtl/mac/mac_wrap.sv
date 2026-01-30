//-----------------------------------------------------------------------------
// File: mac_wrap.sv
// Description: 10G MAC/PCS wrapper with AXI-Stream output interface.
//              Wraps Intel 10G MAC IP and adds ingress timestamping,
//              CRC checking, and multicast filtering.
//
// Interface:
//   - Transceiver side: connects to Intel 10G PHY/MAC IP
//   - Fabric side: AXI-Stream with TUSER sideband containing metadata
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module mac_wrap #(
    parameter int unsigned DATA_WIDTH = 64,
    parameter int unsigned KEEP_WIDTH = DATA_WIDTH / 8
) (
    //-------------------------------------------------------------------------
    // Clocks and Resets
    //-------------------------------------------------------------------------
    input  logic                    mac_clk,         // 156.25 MHz from transceiver
    input  logic                    mac_rst_n,
    
    input  logic                    core_clk,        // 300 MHz core clock
    input  logic                    core_rst_n,
    
    //-------------------------------------------------------------------------
    // Intel 10G MAC IP Interface (RX path)
    //-------------------------------------------------------------------------
    // From MAC IP
    input  logic [DATA_WIDTH-1:0]   mac_rx_data,
    input  logic [KEEP_WIDTH-1:0]   mac_rx_valid_bytes,  // Valid byte enables
    input  logic                    mac_rx_sop,          // Start of packet
    input  logic                    mac_rx_eop,          // End of packet
    input  logic                    mac_rx_valid,
    output logic                    mac_rx_ready,
    input  logic                    mac_rx_error,        // CRC or other error
    
    //-------------------------------------------------------------------------
    // AXI-Stream Master Output (core_clk domain)
    //-------------------------------------------------------------------------
    output logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output logic [KEEP_WIDTH-1:0]   m_axis_tkeep,
    output logic                    m_axis_tlast,
    output logic [71:0]             m_axis_tuser,        // mac_tuser_t packed
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    
    //-------------------------------------------------------------------------
    // Timestamp Input (from core domain)
    //-------------------------------------------------------------------------
    input  logic [63:0]             timestamp_cnt,       // Free-running counter
    
    //-------------------------------------------------------------------------
    // Configuration (CSR domain, synchronized internally)
    //-------------------------------------------------------------------------
    input  logic                    cfg_enable,
    input  logic [47:0]             cfg_mcast_mac,       // Multicast MAC filter
    input  logic                    cfg_mcast_enable,
    input  logic                    cfg_promiscuous,     // Accept all packets
    
    //-------------------------------------------------------------------------
    // Statistics (mac_clk domain)
    //-------------------------------------------------------------------------
    output logic [31:0]             stat_rx_packets,
    output logic [31:0]             stat_rx_bytes,
    output logic [31:0]             stat_rx_crc_errors,
    output logic [31:0]             stat_rx_drops
);

    //=========================================================================
    // Local Signals
    //=========================================================================
    
    // Internal AXI-Stream in MAC domain
    logic [DATA_WIDTH-1:0]   mac_axis_tdata;
    logic [KEEP_WIDTH-1:0]   mac_axis_tkeep;
    logic                    mac_axis_tlast;
    logic [71:0]             mac_axis_tuser;
    logic                    mac_axis_tvalid;
    logic                    mac_axis_tready;
    
    // Packet state machine
    typedef enum logic [1:0] {
        PKT_IDLE,
        PKT_HEADER,
        PKT_PAYLOAD,
        PKT_DROP
    } pkt_state_e;
    
    pkt_state_e pkt_state;
    
    // Extracted header info
    logic [47:0] dst_mac;
    logic [47:0] src_mac;
    logic [15:0] ethertype;
    logic        is_multicast;
    logic        is_vlan;
    logic [1:0]  vlan_count;
    
    // Timestamp capture
    logic [63:0] ingress_ts_captured;
    logic [63:0] ingress_ts_sync;
    
    // Packet filter decision
    logic        pkt_accept;
    logic        pkt_crc_ok;
    logic        pkt_error;
    
    // FIFO interface signals
    logic        fifo_almost_full;
    
    // Statistics
    logic        stat_pkt_inc;
    logic        stat_crc_err_inc;
    logic        stat_drop_inc;
    logic [15:0] byte_count;
    
    //=========================================================================
    // Synchronized Configuration
    //=========================================================================
    
    logic cfg_enable_sync;
    logic cfg_mcast_enable_sync;
    logic cfg_promiscuous_sync;
    
    cdc_sync_single u_sync_enable (
        .clk       (mac_clk),
        .rst_n     (mac_rst_n),
        .async_in  (cfg_enable),
        .sync_out  (cfg_enable_sync)
    );
    
    cdc_sync_single u_sync_mcast_en (
        .clk       (mac_clk),
        .rst_n     (mac_rst_n),
        .async_in  (cfg_mcast_enable),
        .sync_out  (cfg_mcast_enable_sync)
    );
    
    cdc_sync_single u_sync_promisc (
        .clk       (mac_clk),
        .rst_n     (mac_rst_n),
        .async_in  (cfg_promiscuous),
        .sync_out  (cfg_promiscuous_sync)
    );
    
    //=========================================================================
    // Timestamp Capture
    //=========================================================================
    
    // Capture timestamp on SOP (cross-domain - needs synchronization)
    // For accurate timestamping, we capture in mac_clk domain and pass through FIFO
    
    // Synchronize timestamp counter to MAC domain (Gray-coded in real impl)
    // Simplified: just sample, accepting some jitter
    always_ff @(posedge mac_clk or negedge mac_rst_n) begin
        if (!mac_rst_n) begin
            ingress_ts_sync <= '0;
        end else begin
            ingress_ts_sync <= timestamp_cnt;
        end
    end
    
    // Capture on start of packet
    always_ff @(posedge mac_clk or negedge mac_rst_n) begin
        if (!mac_rst_n) begin
            ingress_ts_captured <= '0;
        end else if (mac_rx_valid && mac_rx_sop) begin
            ingress_ts_captured <= ingress_ts_sync;
        end
    end
    
    //=========================================================================
    // Header Extraction (first 14-18 bytes)
    //=========================================================================
    
    // Extract Ethernet header fields from first 64-bit word
    // Ethernet frame: DST MAC (6) | SRC MAC (6) | EtherType (2) | ...
    
    always_ff @(posedge mac_clk or negedge mac_rst_n) begin
        if (!mac_rst_n) begin
            dst_mac    <= '0;
            src_mac    <= '0;
            ethertype  <= '0;
            is_vlan    <= 1'b0;
            vlan_count <= 2'b00;
        end else if (mac_rx_valid && mac_rx_sop) begin
            // First 8 bytes: DST MAC (6) + first 2 bytes of SRC MAC
            dst_mac <= {mac_rx_data[7:0], mac_rx_data[15:8], mac_rx_data[23:16],
                        mac_rx_data[31:24], mac_rx_data[39:32], mac_rx_data[47:40]};
            // SRC MAC lower 2 bytes
            src_mac[47:32] <= {mac_rx_data[55:48], mac_rx_data[63:56]};
        end else if (mac_rx_valid && pkt_state == PKT_HEADER) begin
            // Second 8 bytes: remaining SRC MAC (4) + EtherType (2) + ...
            src_mac[31:0] <= {mac_rx_data[7:0], mac_rx_data[15:8],
                              mac_rx_data[23:16], mac_rx_data[31:24]};
            ethertype <= {mac_rx_data[39:32], mac_rx_data[47:40]};
            
            // Check for VLAN tag (0x8100)
            is_vlan <= (mac_rx_data[47:32] == 16'h0081);  // Byte-swapped
            vlan_count <= (mac_rx_data[47:32] == 16'h0081) ? 2'b01 : 2'b00;
        end
    end
    
    // Multicast detection (bit 0 of first byte of DST MAC)
    assign is_multicast = dst_mac[0];  // LSB of first MAC byte
    
    //=========================================================================
    // Packet Filter Logic
    //=========================================================================
    
    always_comb begin
        pkt_accept = 1'b0;
        
        if (cfg_promiscuous_sync) begin
            pkt_accept = 1'b1;
        end else if (cfg_mcast_enable_sync && is_multicast) begin
            // Check multicast MAC match
            pkt_accept = (dst_mac == cfg_mcast_mac);
        end
    end
    
    //=========================================================================
    // Packet State Machine
    //=========================================================================
    
    always_ff @(posedge mac_clk or negedge mac_rst_n) begin
        if (!mac_rst_n) begin
            pkt_state   <= PKT_IDLE;
            pkt_crc_ok  <= 1'b0;
            pkt_error   <= 1'b0;
            byte_count  <= '0;
        end else begin
            case (pkt_state)
                PKT_IDLE: begin
                    if (mac_rx_valid && mac_rx_sop && cfg_enable_sync) begin
                        pkt_state  <= PKT_HEADER;
                        pkt_crc_ok <= 1'b1;  // Assume OK until proven otherwise
                        pkt_error  <= 1'b0;
                        byte_count <= KEEP_WIDTH;
                    end
                end
                
                PKT_HEADER: begin
                    if (mac_rx_valid) begin
                        byte_count <= byte_count + KEEP_WIDTH;
                        
                        if (!pkt_accept && !cfg_promiscuous_sync) begin
                            pkt_state <= PKT_DROP;
                        end else if (fifo_almost_full) begin
                            pkt_state <= PKT_DROP;  // Back-pressure drop
                        end else begin
                            pkt_state <= PKT_PAYLOAD;
                        end
                        
                        if (mac_rx_error) begin
                            pkt_crc_ok <= 1'b0;
                            pkt_error  <= 1'b1;
                        end
                    end
                end
                
                PKT_PAYLOAD: begin
                    if (mac_rx_valid) begin
                        byte_count <= byte_count + $countones(mac_rx_valid_bytes);
                        
                        if (mac_rx_error) begin
                            pkt_crc_ok <= 1'b0;
                            pkt_error  <= 1'b1;
                        end
                        
                        if (mac_rx_eop) begin
                            pkt_state <= PKT_IDLE;
                        end
                    end
                end
                
                PKT_DROP: begin
                    if (mac_rx_valid && mac_rx_eop) begin
                        pkt_state <= PKT_IDLE;
                    end
                end
            endcase
        end
    end
    
    //=========================================================================
    // MAC Ready Signal
    //=========================================================================
    
    // Always ready from MAC (we buffer in async FIFO)
    assign mac_rx_ready = cfg_enable_sync && !fifo_almost_full;
    
    //=========================================================================
    // Build TUSER Sideband
    //=========================================================================
    
    mac_tuser_t tuser_build;
    
    always_comb begin
        tuser_build.ingress_ts   = ingress_ts_captured;
        tuser_build.crc_ok       = pkt_crc_ok && !mac_rx_error;
        tuser_build.is_multicast = is_multicast;
        tuser_build.vlan_count   = vlan_count;
        tuser_build.error_flags  = {3'b0, pkt_error};
    end
    
    //=========================================================================
    // Internal AXI-Stream Generation
    //=========================================================================
    
    // Generate AXI-Stream from MAC signals
    assign mac_axis_tdata  = mac_rx_data;
    assign mac_axis_tkeep  = mac_rx_valid_bytes;
    assign mac_axis_tlast  = mac_rx_eop;
    assign mac_axis_tuser  = tuser_build;
    assign mac_axis_tvalid = mac_rx_valid && (pkt_state == PKT_PAYLOAD || 
                             (pkt_state == PKT_HEADER && pkt_accept));
    
    //=========================================================================
    // Async FIFO (MAC to Core Clock Domain)
    //=========================================================================
    
    axi_async_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (64),
        .USER_WIDTH (72),
        .KEEP_WIDTH (KEEP_WIDTH)
    ) u_mac_to_core_fifo (
        // Write side (MAC domain)
        .wr_clk          (mac_clk),
        .wr_rst_n        (mac_rst_n),
        .s_axis_tdata    (mac_axis_tdata),
        .s_axis_tkeep    (mac_axis_tkeep),
        .s_axis_tlast    (mac_axis_tlast),
        .s_axis_tuser    (mac_axis_tuser),
        .s_axis_tvalid   (mac_axis_tvalid),
        .s_axis_tready   (mac_axis_tready),
        .wr_level        (),
        .wr_almost_full  (fifo_almost_full),
        .wr_overflow     (),
        
        // Read side (Core domain)
        .rd_clk          (core_clk),
        .rd_rst_n        (core_rst_n),
        .m_axis_tdata    (m_axis_tdata),
        .m_axis_tkeep    (m_axis_tkeep),
        .m_axis_tlast    (m_axis_tlast),
        .m_axis_tuser    (m_axis_tuser),
        .m_axis_tvalid   (m_axis_tvalid),
        .m_axis_tready   (m_axis_tready),
        .rd_level        (),
        .rd_almost_empty (),
        .rd_underflow    ()
    );
    
    //=========================================================================
    // Statistics Counters
    //=========================================================================
    
    // Packet counter
    always_ff @(posedge mac_clk or negedge mac_rst_n) begin
        if (!mac_rst_n) begin
            stat_rx_packets <= '0;
        end else if (mac_rx_valid && mac_rx_eop && pkt_state == PKT_PAYLOAD) begin
            stat_rx_packets <= stat_rx_packets + 1'b1;
        end
    end
    
    // Byte counter
    always_ff @(posedge mac_clk or negedge mac_rst_n) begin
        if (!mac_rst_n) begin
            stat_rx_bytes <= '0;
        end else if (mac_rx_valid && mac_rx_eop && pkt_state == PKT_PAYLOAD) begin
            stat_rx_bytes <= stat_rx_bytes + {16'b0, byte_count};
        end
    end
    
    // CRC error counter
    always_ff @(posedge mac_clk or negedge mac_rst_n) begin
        if (!mac_rst_n) begin
            stat_rx_crc_errors <= '0;
        end else if (mac_rx_valid && mac_rx_error) begin
            stat_rx_crc_errors <= stat_rx_crc_errors + 1'b1;
        end
    end
    
    // Drop counter
    always_ff @(posedge mac_clk or negedge mac_rst_n) begin
        if (!mac_rst_n) begin
            stat_rx_drops <= '0;
        end else if (mac_rx_valid && mac_rx_eop && pkt_state == PKT_DROP) begin
            stat_rx_drops <= stat_rx_drops + 1'b1;
        end
    end

endmodule : mac_wrap
