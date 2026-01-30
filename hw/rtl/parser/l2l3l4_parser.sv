//-----------------------------------------------------------------------------
// File: l2l3l4_parser.sv
// Description: Pipelined Ethernet/IPv4/UDP header parser. Extracts packet
//              metadata and validates checksums/lengths. Outputs parsed
//              packet info in TUSER for downstream ITCH processing.
//
// Pipeline Stages:
//   Stage 1: Ethernet header extraction (DST/SRC MAC, EtherType, VLAN)
//   Stage 2: IP header extraction and checksum (parallel)
//   Stage 3: UDP header extraction
//   Stage 4: Output validation and metadata assembly
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module l2l3l4_parser #(
    parameter int unsigned DATA_WIDTH = 64,
    parameter int unsigned KEEP_WIDTH = DATA_WIDTH / 8
) (
    input  logic                    clk,
    input  logic                    rst_n,
    
    //-------------------------------------------------------------------------
    // AXI-Stream Slave Input (from MAC)
    //-------------------------------------------------------------------------
    input  logic [DATA_WIDTH-1:0]   s_axis_tdata,
    input  logic [KEEP_WIDTH-1:0]   s_axis_tkeep,
    input  logic                    s_axis_tlast,
    input  logic [71:0]             s_axis_tuser,    // mac_tuser_t
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    
    //-------------------------------------------------------------------------
    // AXI-Stream Master Output (to ITCH splitter)
    //-------------------------------------------------------------------------
    output logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output logic [KEEP_WIDTH-1:0]   m_axis_tkeep,
    output logic                    m_axis_tlast,
    output logic [127:0]            m_axis_tuser,    // parsed_pkt_t + original ingress_ts
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    
    //-------------------------------------------------------------------------
    // Configuration
    //-------------------------------------------------------------------------
    input  logic                    cfg_check_ip_csum,   // Enable IP checksum verify
    input  logic [15:0]             cfg_expected_port,   // Expected UDP dest port
    
    //-------------------------------------------------------------------------
    // Statistics
    //-------------------------------------------------------------------------
    output logic [31:0]             stat_parsed_packets,
    output logic [31:0]             stat_ip_errors,
    output logic [31:0]             stat_udp_errors,
    output logic [31:0]             stat_length_errors
);

    //=========================================================================
    // Local Types and Parameters
    //=========================================================================
    
    // Parser state machine
    typedef enum logic [2:0] {
        PARSE_IDLE,
        PARSE_ETH,
        PARSE_VLAN,
        PARSE_IP,
        PARSE_UDP,
        PARSE_PAYLOAD,
        PARSE_ERROR
    } parse_state_e;
    
    // Ethernet header structure (14 bytes, possibly + VLAN tags)
    localparam int ETH_HDR_LEN      = 14;
    localparam int VLAN_TAG_LEN     = 4;
    localparam int IP_HDR_MIN_LEN   = 20;
    localparam int UDP_HDR_LEN      = 8;
    
    localparam logic [15:0] ETHERTYPE_IPV4 = 16'h0800;
    localparam logic [15:0] ETHERTYPE_VLAN = 16'h8100;
    localparam logic [15:0] ETHERTYPE_QINQ = 16'h88A8;
    
    //=========================================================================
    // Signal Declarations
    //=========================================================================
    
    parse_state_e state, next_state;
    
    // Input pipeline registers
    logic [DATA_WIDTH-1:0] tdata_d1, tdata_d2, tdata_d3;
    logic [KEEP_WIDTH-1:0] tkeep_d1, tkeep_d2, tkeep_d3;
    logic                  tlast_d1, tlast_d2, tlast_d3;
    logic [71:0]           tuser_d1, tuser_d2, tuser_d3;
    logic                  tvalid_d1, tvalid_d2, tvalid_d3;
    
    // Packet header buffer (accumulate bytes across beats)
    logic [447:0] hdr_buffer;  // Up to 56 bytes for ETH+VLAN+IP+UDP
    logic [5:0]   hdr_bytes;   // Bytes accumulated
    logic         hdr_complete;
    
    // Extracted fields
    logic [47:0]  eth_dst_mac;
    logic [47:0]  eth_src_mac;
    logic [15:0]  ethertype;
    logic [1:0]   vlan_count;
    logic [15:0]  vlan_id;
    
    logic [3:0]   ip_version;
    logic [3:0]   ip_ihl;
    logic [15:0]  ip_total_len;
    logic [7:0]   ip_protocol;
    logic [31:0]  ip_src;
    logic [31:0]  ip_dst;
    logic [15:0]  ip_checksum;
    logic         ip_checksum_ok;
    
    logic [15:0]  udp_src_port;
    logic [15:0]  udp_dst_port;
    logic [15:0]  udp_length;
    
    // Calculated values
    logic [15:0]  payload_offset;
    logic [15:0]  payload_length;
    logic         port_match;
    
    // IP checksum calculation
    logic [31:0]  ip_csum_accum;
    logic [15:0]  ip_csum_fold;
    
    // Error flags
    logic         err_ip_version;
    logic         err_ip_checksum;
    logic         err_ip_protocol;
    logic         err_length;
    logic         err_port;
    
    // Output metadata
    parsed_pkt_t  parsed_meta;
    
    // Pipeline control
    logic         pipe_advance;
    logic         pipe_stall;
    
    //=========================================================================
    // Input Registration and Pipeline Control
    //=========================================================================
    
    assign pipe_stall   = m_axis_tvalid && !m_axis_tready;
    assign pipe_advance = !pipe_stall;
    assign s_axis_tready = pipe_advance;
    
    // Pipeline stage registers
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tdata_d1  <= '0;
            tkeep_d1  <= '0;
            tlast_d1  <= 1'b0;
            tuser_d1  <= '0;
            tvalid_d1 <= 1'b0;
            
            tdata_d2  <= '0;
            tkeep_d2  <= '0;
            tlast_d2  <= 1'b0;
            tuser_d2  <= '0;
            tvalid_d2 <= 1'b0;
            
            tdata_d3  <= '0;
            tkeep_d3  <= '0;
            tlast_d3  <= 1'b0;
            tuser_d3  <= '0;
            tvalid_d3 <= 1'b0;
        end else if (pipe_advance) begin
            tdata_d1  <= s_axis_tdata;
            tkeep_d1  <= s_axis_tkeep;
            tlast_d1  <= s_axis_tlast;
            tuser_d1  <= s_axis_tuser;
            tvalid_d1 <= s_axis_tvalid;
            
            tdata_d2  <= tdata_d1;
            tkeep_d2  <= tkeep_d1;
            tlast_d2  <= tlast_d1;
            tuser_d2  <= tuser_d1;
            tvalid_d2 <= tvalid_d1;
            
            tdata_d3  <= tdata_d2;
            tkeep_d3  <= tkeep_d2;
            tlast_d3  <= tlast_d2;
            tuser_d3  <= tuser_d2;
            tvalid_d3 <= tvalid_d2;
        end
    end
    
    //=========================================================================
    // Header Buffer Accumulation
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hdr_buffer <= '0;
            hdr_bytes  <= '0;
        end else if (pipe_advance) begin
            if (s_axis_tvalid && state == PARSE_IDLE) begin
                // Start of new packet
                hdr_buffer <= '0;
                hdr_bytes  <= '0;
            end else if (s_axis_tvalid && hdr_bytes < 56) begin
                // Accumulate header bytes
                hdr_buffer <= {hdr_buffer[383:0], s_axis_tdata};
                hdr_bytes  <= hdr_bytes + KEEP_WIDTH;
            end
        end
    end
    
    //=========================================================================
    // State Machine
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= PARSE_IDLE;
        end else if (pipe_advance) begin
            state <= next_state;
        end
    end
    
    always_comb begin
        next_state = state;
        
        case (state)
            PARSE_IDLE: begin
                if (s_axis_tvalid) begin
                    next_state = PARSE_ETH;
                end
            end
            
            PARSE_ETH: begin
                if (tvalid_d1) begin
                    if (ethertype == ETHERTYPE_VLAN || ethertype == ETHERTYPE_QINQ) begin
                        next_state = PARSE_VLAN;
                    end else if (ethertype == ETHERTYPE_IPV4) begin
                        next_state = PARSE_IP;
                    end else begin
                        next_state = PARSE_ERROR;
                    end
                end
            end
            
            PARSE_VLAN: begin
                if (tvalid_d1) begin
                    next_state = PARSE_IP;
                end
            end
            
            PARSE_IP: begin
                if (tvalid_d1 && hdr_bytes >= (ETH_HDR_LEN + vlan_count*VLAN_TAG_LEN + IP_HDR_MIN_LEN)) begin
                    if (ip_protocol == 8'h11) begin  // UDP
                        next_state = PARSE_UDP;
                    end else begin
                        next_state = PARSE_ERROR;
                    end
                end
            end
            
            PARSE_UDP: begin
                if (tvalid_d1) begin
                    next_state = PARSE_PAYLOAD;
                end
            end
            
            PARSE_PAYLOAD: begin
                if (tlast_d2) begin
                    next_state = PARSE_IDLE;
                end
            end
            
            PARSE_ERROR: begin
                if (tlast_d1) begin
                    next_state = PARSE_IDLE;
                end
            end
        endcase
    end
    
    //=========================================================================
    // Header Field Extraction
    //=========================================================================
    
    // Extract fields from header buffer based on byte position
    // Ethernet header: bytes 0-13
    // VLAN (if present): bytes 14-17
    // IP header: starts at ETH_HDR_LEN + vlan_count*4
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eth_dst_mac  <= '0;
            eth_src_mac  <= '0;
            ethertype    <= '0;
            vlan_count   <= 2'b00;
            ip_version   <= '0;
            ip_ihl       <= '0;
            ip_total_len <= '0;
            ip_protocol  <= '0;
            ip_src       <= '0;
            ip_dst       <= '0;
            ip_checksum  <= '0;
            udp_src_port <= '0;
            udp_dst_port <= '0;
            udp_length   <= '0;
        end else if (pipe_advance && tvalid_d1) begin
            // Extract Ethernet header from first 16 bytes
            if (state == PARSE_ETH) begin
                eth_dst_mac  <= {s_axis_tdata[7:0], s_axis_tdata[15:8], s_axis_tdata[23:16],
                                 s_axis_tdata[31:24], s_axis_tdata[39:32], s_axis_tdata[47:40]};
                eth_src_mac  <= {s_axis_tdata[55:48], s_axis_tdata[63:56], 
                                 tdata_d1[7:0], tdata_d1[15:8], tdata_d1[23:16], tdata_d1[31:24]};
                ethertype    <= {tdata_d1[39:32], tdata_d1[47:40]};
                
                // Detect VLAN
                if ({tdata_d1[39:32], tdata_d1[47:40]} == ETHERTYPE_VLAN) begin
                    vlan_count <= 2'b01;
                end else begin
                    vlan_count <= 2'b00;
                end
            end
            
            // Extract IP header (assuming no options for simplicity)
            if (state == PARSE_IP && hdr_bytes >= 24) begin
                // IP fields at offset 14 (or 18 with VLAN)
                ip_version   <= hdr_buffer[447:444];
                ip_ihl       <= hdr_buffer[443:440];
                ip_total_len <= {hdr_buffer[431:424], hdr_buffer[439:432]};
                ip_protocol  <= hdr_buffer[367:360];
                ip_checksum  <= {hdr_buffer[351:344], hdr_buffer[359:352]};
                ip_src       <= {hdr_buffer[335:328], hdr_buffer[343:336], 
                                 hdr_buffer[319:312], hdr_buffer[327:320]};
                ip_dst       <= {hdr_buffer[303:296], hdr_buffer[311:304],
                                 hdr_buffer[287:280], hdr_buffer[295:288]};
            end
            
            // Extract UDP header
            if (state == PARSE_UDP && hdr_bytes >= 42) begin
                udp_src_port <= {hdr_buffer[271:264], hdr_buffer[279:272]};
                udp_dst_port <= {hdr_buffer[255:248], hdr_buffer[263:256]};
                udp_length   <= {hdr_buffer[239:232], hdr_buffer[247:240]};
            end
        end
    end
    
    //=========================================================================
    // IP Checksum Verification (parallel accumulate)
    //=========================================================================
    
    // Simplified checksum calculation
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ip_csum_accum <= '0;
        end else if (pipe_advance) begin
            if (state == PARSE_IDLE) begin
                ip_csum_accum <= '0;
            end else if (state == PARSE_IP) begin
                // Accumulate 16-bit words of IP header
                ip_csum_accum <= ip_csum_accum + 
                                 {16'b0, s_axis_tdata[15:0]} +
                                 {16'b0, s_axis_tdata[31:16]} +
                                 {16'b0, s_axis_tdata[47:32]} +
                                 {16'b0, s_axis_tdata[63:48]};
            end
        end
    end
    
    // Fold carry bits
    assign ip_csum_fold = ip_csum_accum[15:0] + ip_csum_accum[31:16];
    assign ip_checksum_ok = (ip_csum_fold == 16'hFFFF) || !cfg_check_ip_csum;
    
    //=========================================================================
    // Validation
    //=========================================================================
    
    assign err_ip_version  = (ip_version != 4'd4);
    assign err_ip_checksum = !ip_checksum_ok && cfg_check_ip_csum;
    assign err_ip_protocol = (ip_protocol != 8'h11);  // Not UDP
    assign err_length      = (udp_length < UDP_HDR_LEN);
    assign port_match      = (udp_dst_port == cfg_expected_port) || (cfg_expected_port == 16'h0000);
    assign err_port        = !port_match;
    
    // Calculate payload offset
    assign payload_offset = ETH_HDR_LEN + (vlan_count * VLAN_TAG_LEN) + 
                           (ip_ihl * 4) + UDP_HDR_LEN;
    assign payload_length = udp_length - UDP_HDR_LEN;
    
    //=========================================================================
    // Output Metadata Assembly
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            parsed_meta <= '0;
        end else if (pipe_advance && state == PARSE_UDP) begin
            parsed_meta.ingress_ts      <= tuser_d2[71:8];  // Extract timestamp from mac_tuser
            parsed_meta.src_ip          <= ip_src;
            parsed_meta.dst_ip          <= ip_dst;
            parsed_meta.src_port        <= udp_src_port;
            parsed_meta.dst_port        <= udp_dst_port;
            parsed_meta.udp_len         <= udp_length;
            parsed_meta.payload_offset  <= payload_offset;
            parsed_meta.parse_error     <= {err_port, err_length, err_ip_checksum, err_ip_version};
            parsed_meta.is_valid        <= !err_ip_version && !err_ip_protocol && !err_length && port_match;
        end
    end
    
    //=========================================================================
    // Output
    //=========================================================================
    
    assign m_axis_tdata  = tdata_d3;
    assign m_axis_tkeep  = tkeep_d3;
    assign m_axis_tlast  = tlast_d3;
    assign m_axis_tuser  = {parsed_meta, 8'b0};  // Pack parsed metadata
    assign m_axis_tvalid = tvalid_d3 && (state == PARSE_PAYLOAD || state == PARSE_UDP);
    
    //=========================================================================
    // Statistics
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_parsed_packets <= '0;
            stat_ip_errors      <= '0;
            stat_udp_errors     <= '0;
            stat_length_errors  <= '0;
        end else begin
            if (pipe_advance && tlast_d3 && m_axis_tvalid) begin
                stat_parsed_packets <= stat_parsed_packets + 1'b1;
            end
            
            if (pipe_advance && state == PARSE_IP && err_ip_checksum) begin
                stat_ip_errors <= stat_ip_errors + 1'b1;
            end
            
            if (pipe_advance && state == PARSE_UDP && err_port) begin
                stat_udp_errors <= stat_udp_errors + 1'b1;
            end
            
            if (pipe_advance && state == PARSE_UDP && err_length) begin
                stat_length_errors <= stat_length_errors + 1'b1;
            end
        end
    end

endmodule : l2l3l4_parser
