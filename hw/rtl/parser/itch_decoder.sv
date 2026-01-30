//-----------------------------------------------------------------------------
// File: itch_decoder.sv
// Description: ITCH 5.0 message decoder. Parses individual ITCH messages
//              and extracts relevant fields for order book updates.
//
// Supported Messages:
//   - Add Order ('A', 'F')
//   - Order Executed ('E', 'C')
//   - Order Cancel ('X')
//   - Order Delete ('D')
//   - Order Replace ('U')
//   - Trade ('P')
//   - System Event ('S')
//   - Stock Directory ('R')
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module itch_decoder #(
    parameter int unsigned MAX_MSG_BYTES = 64
) (
    input  logic                    clk,
    input  logic                    rst_n,
    
    //-------------------------------------------------------------------------
    // AXI-Stream Slave Input (from ITCH splitter)
    //-------------------------------------------------------------------------
    input  logic [MAX_MSG_BYTES*8-1:0] s_axis_tdata,
    input  logic [7:0]              s_axis_tkeep,      // Message length
    input  logic                    s_axis_tlast,
    input  logic [95:0]             s_axis_tuser,      // {seq, msg_type, msg_len, flags, ingress_ts}
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    
    //-------------------------------------------------------------------------
    // Decoded Message Output
    //-------------------------------------------------------------------------
    output itch_msg_t               decoded_msg,
    output logic                    decoded_valid,
    input  logic                    decoded_ready,
    
    //-------------------------------------------------------------------------
    // Symbol Lookup Interface
    //-------------------------------------------------------------------------
    output logic [SYMBOL_KEY_WIDTH-1:0] sym_lookup_key,
    output logic                    sym_lookup_valid,
    input  logic [SYMBOL_IDX_WIDTH-1:0] sym_lookup_idx,
    input  logic                    sym_lookup_hit,
    input  logic                    sym_lookup_ready,
    
    //-------------------------------------------------------------------------
    // Statistics
    //-------------------------------------------------------------------------
    output logic [31:0]             stat_add_orders,
    output logic [31:0]             stat_executes,
    output logic [31:0]             stat_cancels,
    output logic [31:0]             stat_deletes,
    output logic [31:0]             stat_replaces,
    output logic [31:0]             stat_trades,
    output logic [31:0]             stat_unknown
);

    //=========================================================================
    // Local Types
    //=========================================================================
    
    typedef enum logic [2:0] {
        DEC_IDLE,
        DEC_PARSE,
        DEC_LOOKUP,
        DEC_EMIT
    } dec_state_e;
    
    //=========================================================================
    // Signal Declarations
    //=========================================================================
    
    dec_state_e state;
    
    // Input registration
    logic [MAX_MSG_BYTES*8-1:0] msg_data;
    logic [7:0]  msg_len;
    logic [31:0] msg_seq;
    logic [7:0]  msg_type;
    logic [7:0]  msg_flags;
    logic [63:0] ingress_ts;
    
    // Extracted message fields (common)
    logic [15:0] stock_locate;
    logic [15:0] tracking_num;
    logic [47:0] itch_timestamp;
    logic [63:0] order_ref;
    logic [7:0]  side_char;
    logic [31:0] shares;
    logic [63:0] stock_symbol;
    logic [31:0] price;
    
    // Additional fields for specific messages
    logic [63:0] new_order_ref;     // For replace
    logic [31:0] canceled_shares;   // For cancel
    logic [31:0] executed_shares;   // For execute
    logic [31:0] execution_price;   // For execute with price
    logic [63:0] match_number;      // For trade
    
    // Decoded output
    itch_msg_t   decoded_reg;
    logic        decode_valid;
    
    // Byte extraction helper
    function automatic logic [7:0] get_byte(input int idx);
        return msg_data[idx*8 +: 8];
    endfunction
    
    // Big-endian 16-bit extraction
    function automatic logic [15:0] get_be16(input int idx);
        return {get_byte(idx), get_byte(idx+1)};
    endfunction
    
    // Big-endian 32-bit extraction
    function automatic logic [31:0] get_be32(input int idx);
        return {get_byte(idx), get_byte(idx+1), get_byte(idx+2), get_byte(idx+3)};
    endfunction
    
    // Big-endian 48-bit extraction
    function automatic logic [47:0] get_be48(input int idx);
        return {get_byte(idx), get_byte(idx+1), get_byte(idx+2),
                get_byte(idx+3), get_byte(idx+4), get_byte(idx+5)};
    endfunction
    
    // Big-endian 64-bit extraction
    function automatic logic [63:0] get_be64(input int idx);
        return {get_byte(idx), get_byte(idx+1), get_byte(idx+2), get_byte(idx+3),
                get_byte(idx+4), get_byte(idx+5), get_byte(idx+6), get_byte(idx+7)};
    endfunction
    
    //=========================================================================
    // State Machine
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= DEC_IDLE;
            msg_data      <= '0;
            msg_len       <= '0;
            msg_seq       <= '0;
            msg_type      <= '0;
            msg_flags     <= '0;
            ingress_ts    <= '0;
            decoded_reg   <= '0;
            decode_valid  <= 1'b0;
        end else begin
            case (state)
                DEC_IDLE: begin
                    decode_valid <= 1'b0;
                    
                    if (s_axis_tvalid && s_axis_tready) begin
                        // Capture input
                        msg_data   <= s_axis_tdata;
                        msg_len    <= s_axis_tkeep;
                        msg_seq    <= s_axis_tuser[95:64];
                        msg_type   <= s_axis_tuser[63:56];
                        msg_flags  <= s_axis_tuser[55:48];
                        ingress_ts <= s_axis_tuser[47:0];
                        
                        state <= DEC_PARSE;
                    end
                end
                
                DEC_PARSE: begin
                    // Extract common header fields (all messages have these)
                    // Byte 0: Message Type
                    // Bytes 1-2: Stock Locate
                    // Bytes 3-4: Tracking Number
                    // Bytes 5-10: Timestamp (6 bytes)
                    
                    stock_locate   <= get_be16(1);
                    tracking_num   <= get_be16(3);
                    itch_timestamp <= get_be48(5);
                    
                    // Start decoded message
                    decoded_reg.ingress_ts   <= ingress_ts;
                    decoded_reg.decode_ts    <= '0;  // Will be set later
                    decoded_reg.seq_num      <= msg_seq;
                    decoded_reg.msg_type     <= itch_msg_type_e'(msg_type);
                    decoded_reg.stale        <= msg_flags[7];  // Stale flag from splitter
                    decoded_reg.error_flags  <= msg_flags[3:0];
                    
                    // Parse message-specific fields
                    case (msg_type)
                        8'h41: begin  // Add Order (no MPID) - 36 bytes
                            // Bytes 11-18: Order Reference Number
                            // Byte 19: Side ('B' or 'S')
                            // Bytes 20-23: Shares
                            // Bytes 24-31: Stock (8 bytes, space-padded)
                            // Bytes 32-35: Price (4 bytes)
                            order_ref    <= get_be64(11);
                            side_char    <= get_byte(19);
                            shares       <= get_be32(20);
                            stock_symbol <= get_be64(24);
                            price        <= get_be32(32);
                            
                            decoded_reg.order_id      <= get_be64(11);
                            decoded_reg.side          <= (get_byte(19) == 8'h42) ? SIDE_BID : SIDE_ASK;
                            decoded_reg.qty           <= get_be32(20);
                            decoded_reg.symbol_key    <= get_be64(24);
                            decoded_reg.price         <= get_be32(32);
                            decoded_reg.is_book_update <= 1'b1;
                            
                            state <= DEC_LOOKUP;
                        end
                        
                        8'h46: begin  // Add Order (with MPID) - 40 bytes
                            order_ref    <= get_be64(11);
                            side_char    <= get_byte(19);
                            shares       <= get_be32(20);
                            stock_symbol <= get_be64(24);
                            price        <= get_be32(32);
                            // Bytes 36-39: MPID (ignored)
                            
                            decoded_reg.order_id      <= get_be64(11);
                            decoded_reg.side          <= (get_byte(19) == 8'h42) ? SIDE_BID : SIDE_ASK;
                            decoded_reg.qty           <= get_be32(20);
                            decoded_reg.symbol_key    <= get_be64(24);
                            decoded_reg.price         <= get_be32(32);
                            decoded_reg.is_book_update <= 1'b1;
                            
                            state <= DEC_LOOKUP;
                        end
                        
                        8'h45: begin  // Order Executed - 31 bytes
                            // Bytes 11-18: Order Reference Number
                            // Bytes 19-22: Executed Shares
                            // Bytes 23-30: Match Number
                            order_ref       <= get_be64(11);
                            executed_shares <= get_be32(19);
                            match_number    <= get_be64(23);
                            
                            decoded_reg.order_id      <= get_be64(11);
                            decoded_reg.qty           <= get_be32(19);
                            decoded_reg.is_book_update <= 1'b1;
                            // Note: We need order lookup to know side/price
                            
                            state <= DEC_EMIT;  // No symbol lookup needed
                        end
                        
                        8'h43: begin  // Order Executed with Price - 36 bytes
                            order_ref       <= get_be64(11);
                            executed_shares <= get_be32(19);
                            match_number    <= get_be64(23);
                            execution_price <= get_be32(32);
                            // Byte 31: Printable flag
                            
                            decoded_reg.order_id      <= get_be64(11);
                            decoded_reg.qty           <= get_be32(19);
                            decoded_reg.price         <= get_be32(32);
                            decoded_reg.is_book_update <= 1'b1;
                            
                            state <= DEC_EMIT;
                        end
                        
                        8'h58: begin  // Order Cancel - 23 bytes
                            order_ref        <= get_be64(11);
                            canceled_shares  <= get_be32(19);
                            
                            decoded_reg.order_id      <= get_be64(11);
                            decoded_reg.qty           <= get_be32(19);
                            decoded_reg.is_book_update <= 1'b1;
                            
                            state <= DEC_EMIT;
                        end
                        
                        8'h44: begin  // Order Delete - 19 bytes
                            order_ref <= get_be64(11);
                            
                            decoded_reg.order_id      <= get_be64(11);
                            decoded_reg.qty           <= '0;
                            decoded_reg.is_book_update <= 1'b1;
                            
                            state <= DEC_EMIT;
                        end
                        
                        8'h55: begin  // Order Replace - 35 bytes
                            order_ref     <= get_be64(11);
                            new_order_ref <= get_be64(19);
                            shares        <= get_be32(27);
                            price         <= get_be32(31);
                            
                            decoded_reg.order_id      <= get_be64(19);  // New order ref
                            decoded_reg.qty           <= get_be32(27);
                            decoded_reg.price         <= get_be32(31);
                            decoded_reg.is_book_update <= 1'b1;
                            
                            state <= DEC_EMIT;
                        end
                        
                        8'h50: begin  // Trade - 44 bytes
                            // Bytes 11-18: Order Reference Number
                            // Byte 19: Side
                            // Bytes 20-23: Shares
                            // Bytes 24-31: Stock
                            // Bytes 32-35: Price
                            // Bytes 36-43: Match Number
                            order_ref    <= get_be64(11);
                            side_char    <= get_byte(19);
                            shares       <= get_be32(20);
                            stock_symbol <= get_be64(24);
                            price        <= get_be32(32);
                            match_number <= get_be64(36);
                            
                            decoded_reg.order_id      <= get_be64(11);
                            decoded_reg.side          <= (get_byte(19) == 8'h42) ? SIDE_BID : SIDE_ASK;
                            decoded_reg.qty           <= get_be32(20);
                            decoded_reg.symbol_key    <= get_be64(24);
                            decoded_reg.price         <= get_be32(32);
                            decoded_reg.is_book_update <= 1'b1;
                            
                            state <= DEC_LOOKUP;
                        end
                        
                        8'h53: begin  // System Event - 12 bytes
                            // Byte 11: Event Code
                            decoded_reg.is_book_update <= 1'b0;
                            state <= DEC_EMIT;
                        end
                        
                        8'h52: begin  // Stock Directory - 39 bytes
                            // Bytes 11-18: Stock
                            // Other fields for market category, etc.
                            stock_symbol <= get_be64(11);
                            decoded_reg.symbol_key    <= get_be64(11);
                            decoded_reg.is_book_update <= 1'b0;
                            state <= DEC_LOOKUP;
                        end
                        
                        default: begin
                            // Unknown message type
                            decoded_reg.is_book_update <= 1'b0;
                            decoded_reg.error_flags   <= 4'hF;
                            state <= DEC_EMIT;
                        end
                    endcase
                end
                
                DEC_LOOKUP: begin
                    // Wait for symbol table lookup
                    if (sym_lookup_ready) begin
                        decoded_reg.symbol_idx   <= sym_lookup_idx;
                        decoded_reg.symbol_valid <= sym_lookup_hit;
                        state <= DEC_EMIT;
                    end
                end
                
                DEC_EMIT: begin
                    if (decoded_ready || !decode_valid) begin
                        decode_valid <= 1'b1;
                        
                        if (decoded_ready) begin
                            state <= DEC_IDLE;
                        end
                    end
                end
            endcase
        end
    end
    
    //=========================================================================
    // Symbol Lookup Interface
    //=========================================================================
    
    assign sym_lookup_key   = decoded_reg.symbol_key;
    assign sym_lookup_valid = (state == DEC_LOOKUP);
    
    //=========================================================================
    // Output
    //=========================================================================
    
    assign decoded_msg   = decoded_reg;
    assign decoded_valid = decode_valid && (state == DEC_EMIT);
    assign s_axis_tready = (state == DEC_IDLE);
    
    //=========================================================================
    // Statistics
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_add_orders <= '0;
            stat_executes   <= '0;
            stat_cancels    <= '0;
            stat_deletes    <= '0;
            stat_replaces   <= '0;
            stat_trades     <= '0;
            stat_unknown    <= '0;
        end else if (decoded_valid && decoded_ready) begin
            case (decoded_reg.msg_type)
                ITCH_ADD_ORDER, ITCH_ADD_ORDER_MPID:
                    stat_add_orders <= stat_add_orders + 1'b1;
                ITCH_ORDER_EXECUTED, ITCH_ORDER_EXECUTED_PX:
                    stat_executes <= stat_executes + 1'b1;
                ITCH_ORDER_CANCEL:
                    stat_cancels <= stat_cancels + 1'b1;
                ITCH_ORDER_DELETE:
                    stat_deletes <= stat_deletes + 1'b1;
                ITCH_ORDER_REPLACE:
                    stat_replaces <= stat_replaces + 1'b1;
                ITCH_TRADE:
                    stat_trades <= stat_trades + 1'b1;
                default:
                    stat_unknown <= stat_unknown + 1'b1;
            endcase
        end
    end

endmodule : itch_decoder
