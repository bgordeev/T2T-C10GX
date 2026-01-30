//-----------------------------------------------------------------------------
// File: itch_splitter.sv
// Description: ITCH message splitter. Takes UDP payload from L2/L3/L4 parser
//              and splits it into individual ITCH messages. ITCH 5.0 messages
//              are variable-length and packed back-to-back in UDP payloads.
//
// Features:
//   - Variable-length message boundary detection
//   - Sequence number tracking and gap detection
//   - Back-to-back message splitting (no padding between messages)
//   - Partial message handling across packet boundaries
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module itch_splitter #(
    parameter int unsigned DATA_WIDTH     = 64,
    parameter int unsigned KEEP_WIDTH     = DATA_WIDTH / 8,
    parameter int unsigned MAX_MSG_BYTES  = 64,   // Maximum ITCH message size
    parameter int unsigned MSG_BUF_DEPTH  = 128   // Message buffer depth (bytes)
) (
    input  logic                    clk,
    input  logic                    rst_n,
    
    //-------------------------------------------------------------------------
    // AXI-Stream Slave Input (from L2/L3/L4 parser)
    //-------------------------------------------------------------------------
    input  logic [DATA_WIDTH-1:0]   s_axis_tdata,
    input  logic [KEEP_WIDTH-1:0]   s_axis_tkeep,
    input  logic                    s_axis_tlast,
    input  logic [127:0]            s_axis_tuser,    // parsed_pkt_t
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    
    //-------------------------------------------------------------------------
    // AXI-Stream Master Output (individual ITCH messages)
    //-------------------------------------------------------------------------
    output logic [MAX_MSG_BYTES*8-1:0] m_axis_tdata,   // Full message buffer
    output logic [7:0]              m_axis_tkeep,      // Valid bytes (0-63)
    output logic                    m_axis_tlast,      // Always 1 (one msg per beat)
    output logic [95:0]             m_axis_tuser,      // {seq, msg_type, msg_len, flags, ingress_ts}
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    
    //-------------------------------------------------------------------------
    // Configuration
    //-------------------------------------------------------------------------
    input  logic [31:0]             cfg_expected_seq,  // Expected next sequence
    input  logic                    cfg_seq_check_en,  // Enable sequence checking
    
    //-------------------------------------------------------------------------
    // Status
    //-------------------------------------------------------------------------
    output logic [31:0]             stat_messages,
    output logic [31:0]             stat_seq_gaps,
    output logic [31:0]             stat_seq_dupes,
    output logic                    status_stale       // Sequence gap detected
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    
    localparam int BUF_ADDR_WIDTH = $clog2(MSG_BUF_DEPTH);
    
    //=========================================================================
    // Signal Declarations
    //=========================================================================
    
    // State machine
    typedef enum logic [2:0] {
        SPLIT_IDLE,
        SPLIT_HEADER,
        SPLIT_BODY,
        SPLIT_EMIT,
        SPLIT_WAIT
    } split_state_e;
    
    split_state_e state;
    
    // Message buffer
    logic [7:0] msg_buffer [MSG_BUF_DEPTH];
    logic [BUF_ADDR_WIDTH-1:0] buf_wr_ptr;
    logic [BUF_ADDR_WIDTH-1:0] buf_rd_ptr;
    logic [7:0] msg_bytes_collected;
    
    // Current message info
    logic [7:0]  cur_msg_type;
    logic [7:0]  cur_msg_len;       // Expected length based on type
    logic [31:0] cur_seq;           // Sequence number
    logic [63:0] cur_ingress_ts;
    
    // Sequence tracking
    logic [31:0] expected_seq;
    logic        seq_gap_detected;
    logic        seq_dupe_detected;
    
    // Input byte extraction
    logic [7:0]  input_bytes [KEEP_WIDTH];
    logic [3:0]  valid_byte_count;
    logic [3:0]  byte_idx;
    
    // Output assembly
    logic [MAX_MSG_BYTES*8-1:0] msg_data_out;
    logic        msg_ready;
    
    // Stale flag (latched until cleared)
    logic        stale_latch;
    
    // Input registration
    logic [DATA_WIDTH-1:0] tdata_reg;
    logic [KEEP_WIDTH-1:0] tkeep_reg;
    logic                  tlast_reg;
    logic [127:0]          tuser_reg;
    logic                  tvalid_reg;
    
    //=========================================================================
    // Input Registration
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tdata_reg  <= '0;
            tkeep_reg  <= '0;
            tlast_reg  <= 1'b0;
            tuser_reg  <= '0;
            tvalid_reg <= 1'b0;
        end else if (s_axis_tready) begin
            tdata_reg  <= s_axis_tdata;
            tkeep_reg  <= s_axis_tkeep;
            tlast_reg  <= s_axis_tlast;
            tuser_reg  <= s_axis_tuser;
            tvalid_reg <= s_axis_tvalid;
        end
    end
    
    // Extract individual bytes from input word
    generate
        for (genvar i = 0; i < KEEP_WIDTH; i++) begin : gen_bytes
            assign input_bytes[i] = tdata_reg[i*8 +: 8];
        end
    endgenerate
    
    // Count valid bytes
    always_comb begin
        valid_byte_count = '0;
        for (int i = 0; i < KEEP_WIDTH; i++) begin
            if (tkeep_reg[i]) valid_byte_count = valid_byte_count + 1;
        end
    end
    
    //=========================================================================
    // ITCH Message Length Lookup
    //=========================================================================
    
    function automatic logic [7:0] get_msg_length(input logic [7:0] msg_type);
        case (msg_type)
            8'h53: return 8'd12;   // 'S' System Event
            8'h52: return 8'd39;   // 'R' Stock Directory
            8'h48: return 8'd25;   // 'H' Stock Trading Action
            8'h59: return 8'd20;   // 'Y' Reg SHO
            8'h4C: return 8'd26;   // 'L' Market Participant
            8'h56: return 8'd35;   // 'V' MWCB Decline
            8'h57: return 8'd12;   // 'W' MWCB Status
            8'h4B: return 8'd28;   // 'K' IPO Quoting Period
            8'h41: return 8'd36;   // 'A' Add Order (no MPID)
            8'h46: return 8'd40;   // 'F' Add Order (with MPID)
            8'h45: return 8'd31;   // 'E' Order Executed
            8'h43: return 8'd36;   // 'C' Order Executed with Price
            8'h58: return 8'd23;   // 'X' Order Cancel
            8'h44: return 8'd19;   // 'D' Order Delete
            8'h55: return 8'd35;   // 'U' Order Replace
            8'h50: return 8'd44;   // 'P' Trade (non-cross)
            8'h51: return 8'd40;   // 'Q' Cross Trade
            8'h42: return 8'd19;   // 'B' Broken Trade
            8'h49: return 8'd50;   // 'I' NOII
            8'h4E: return 8'd20;   // 'N' RPII
            default: return 8'd0;  // Unknown
        endcase
    endfunction
    
    //=========================================================================
    // State Machine
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= SPLIT_IDLE;
            buf_wr_ptr          <= '0;
            msg_bytes_collected <= '0;
            cur_msg_type        <= '0;
            cur_msg_len         <= '0;
            cur_seq             <= '0;
            cur_ingress_ts      <= '0;
            expected_seq        <= '0;
            seq_gap_detected    <= 1'b0;
            seq_dupe_detected   <= 1'b0;
            stale_latch         <= 1'b0;
            byte_idx            <= '0;
        end else begin
            // Default: clear per-message flags
            seq_gap_detected  <= 1'b0;
            seq_dupe_detected <= 1'b0;
            
            case (state)
                SPLIT_IDLE: begin
                    buf_wr_ptr          <= '0;
                    msg_bytes_collected <= '0;
                    byte_idx            <= '0;
                    
                    if (tvalid_reg && tuser_reg[0]) begin  // is_valid from parsed_pkt_t
                        cur_ingress_ts <= tuser_reg[71:8];  // Extract ingress timestamp
                        state <= SPLIT_HEADER;
                    end
                end
                
                SPLIT_HEADER: begin
                    if (tvalid_reg && byte_idx < valid_byte_count) begin
                        // First byte of message is the message type
                        cur_msg_type <= input_bytes[byte_idx];
                        cur_msg_len  <= get_msg_length(input_bytes[byte_idx]);
                        
                        // Store in buffer
                        msg_buffer[buf_wr_ptr] <= input_bytes[byte_idx];
                        buf_wr_ptr          <= buf_wr_ptr + 1;
                        msg_bytes_collected <= 8'd1;
                        byte_idx            <= byte_idx + 1;
                        
                        if (get_msg_length(input_bytes[byte_idx]) == 0) begin
                            // Unknown message type
                            state <= SPLIT_IDLE;
                        end else begin
                            state <= SPLIT_BODY;
                        end
                    end else if (tlast_reg) begin
                        state <= SPLIT_IDLE;
                    end
                end
                
                SPLIT_BODY: begin
                    if (tvalid_reg) begin
                        // Collect remaining bytes of message
                        while (byte_idx < valid_byte_count && 
                               msg_bytes_collected < cur_msg_len) begin
                            msg_buffer[buf_wr_ptr] <= input_bytes[byte_idx];
                            buf_wr_ptr             <= buf_wr_ptr + 1;
                            msg_bytes_collected    <= msg_bytes_collected + 1;
                            byte_idx               <= byte_idx + 1;
                        end
                        
                        if (msg_bytes_collected >= cur_msg_len) begin
                            // Message complete
                            state <= SPLIT_EMIT;
                        end else if (byte_idx >= valid_byte_count) begin
                            // Need more data
                            byte_idx <= '0;
                            if (tlast_reg) begin
                                // Partial message at end of packet (error case)
                                state <= SPLIT_IDLE;
                            end
                        end
                    end
                end
                
                SPLIT_EMIT: begin
                    if (m_axis_tready || !m_axis_tvalid) begin
                        // Extract sequence number from message (bytes 1-4, big-endian)
                        cur_seq <= {msg_buffer[1], msg_buffer[2], msg_buffer[3], msg_buffer[4]};
                        
                        // Sequence checking
                        if (cfg_seq_check_en) begin
                            if ({msg_buffer[1], msg_buffer[2], msg_buffer[3], msg_buffer[4]} > expected_seq) begin
                                seq_gap_detected <= 1'b1;
                                stale_latch      <= 1'b1;
                            end else if ({msg_buffer[1], msg_buffer[2], msg_buffer[3], msg_buffer[4]} < expected_seq) begin
                                seq_dupe_detected <= 1'b1;
                            end
                            expected_seq <= {msg_buffer[1], msg_buffer[2], msg_buffer[3], msg_buffer[4]} + 1;
                        end
                        
                        // Check if more messages in current packet
                        if (byte_idx < valid_byte_count && !tlast_reg) begin
                            buf_wr_ptr          <= '0;
                            msg_bytes_collected <= '0;
                            state <= SPLIT_HEADER;
                        end else begin
                            state <= SPLIT_WAIT;
                        end
                    end
                end
                
                SPLIT_WAIT: begin
                    // Wait for next input beat
                    buf_wr_ptr          <= '0;
                    msg_bytes_collected <= '0;
                    byte_idx            <= '0;
                    
                    if (tlast_reg) begin
                        state <= SPLIT_IDLE;
                    end else if (tvalid_reg) begin
                        state <= SPLIT_HEADER;
                    end
                end
            endcase
            
            // Initialize expected sequence from config
            if (state == SPLIT_IDLE && cfg_seq_check_en) begin
                if (expected_seq == '0) begin
                    expected_seq <= cfg_expected_seq;
                end
            end
        end
    end
    
    //=========================================================================
    // Output Assembly
    //=========================================================================
    
    // Pack message buffer into output data
    always_comb begin
        msg_data_out = '0;
        for (int i = 0; i < MAX_MSG_BYTES; i++) begin
            if (i < msg_bytes_collected) begin
                msg_data_out[i*8 +: 8] = msg_buffer[i];
            end
        end
    end
    
    assign msg_ready = (state == SPLIT_EMIT);
    
    //=========================================================================
    // Output Assignments
    //=========================================================================
    
    assign m_axis_tdata  = msg_data_out;
    assign m_axis_tkeep  = msg_bytes_collected;
    assign m_axis_tlast  = 1'b1;  // Always last (one message per transaction)
    assign m_axis_tuser  = {cur_seq, cur_msg_type, cur_msg_len, 
                           stale_latch, seq_gap_detected, seq_dupe_detected, 5'b0,
                           cur_ingress_ts};
    assign m_axis_tvalid = msg_ready;
    
    // Ready when not emitting and buffer not full
    assign s_axis_tready = (state != SPLIT_EMIT) && (buf_wr_ptr < MSG_BUF_DEPTH - KEEP_WIDTH);
    
    assign status_stale = stale_latch;
    
    //=========================================================================
    // Statistics
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_messages <= '0;
            stat_seq_gaps <= '0;
            stat_seq_dupes <= '0;
        end else begin
            if (m_axis_tvalid && m_axis_tready) begin
                stat_messages <= stat_messages + 1'b1;
            end
            
            if (seq_gap_detected) begin
                stat_seq_gaps <= stat_seq_gaps + 1'b1;
            end
            
            if (seq_dupe_detected) begin
                stat_seq_dupes <= stat_seq_dupes + 1'b1;
            end
        end
    end

endmodule : itch_splitter
