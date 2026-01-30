//-----------------------------------------------------------------------------
// File: book_tob.sv
// Description: Top-of-Book (TOB) builder maintaining best bid/ask for each
//              symbol. Uses banked BRAM for reduced conflicts on hot symbols.
//
//
// Note: This simplified implementation maintains only aggregate TOB state,
//       not individual order tracking. Real implementations would need
//       order ID tracking for accurate cancel/modify handling.
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module book_tob #(
    parameter int unsigned NUM_SYMBOLS = 1024,
    parameter int unsigned NUM_BANKS   = 4,
    parameter int unsigned IDX_WIDTH   = $clog2(NUM_SYMBOLS)
) (
    input  logic                    clk,
    input  logic                    rst_n,
    
    //-------------------------------------------------------------------------
    // Input: Decoded ITCH Messages
    //-------------------------------------------------------------------------
    input  itch_msg_t               msg_in,
    input  logic                    msg_valid,
    output logic                    msg_ready,
    
    //-------------------------------------------------------------------------
    // Output: Book Update Events
    //-------------------------------------------------------------------------
    output book_event_t             event_out,
    output logic                    event_valid,
    input  logic                    event_ready,
    
    //-------------------------------------------------------------------------
    // Configuration
    //-------------------------------------------------------------------------
    input  logic                    cfg_enable,
    
    //-------------------------------------------------------------------------
    // Statistics
    //-------------------------------------------------------------------------
    output logic [31:0]             stat_updates,
    output logic [31:0]             stat_bank_conflicts,
    output logic [31:0]             stat_invalid_symbols
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    
    localparam int unsigned BANK_IDX_WIDTH = $clog2(NUM_BANKS);
    localparam int unsigned BANK_SIZE = NUM_SYMBOLS / NUM_BANKS;
    localparam int unsigned BANK_ADDR_WIDTH = $clog2(BANK_SIZE);
    
    //=========================================================================
    // Type Definitions
    //=========================================================================
    
    // Book entry stored in BRAM
    typedef struct packed {
        logic [PRICE_WIDTH-1:0]     bid_px;
        logic [QTY_WIDTH-1:0]       bid_qty;
        logic [PRICE_WIDTH-1:0]     ask_px;
        logic [QTY_WIDTH-1:0]       ask_qty;
        logic [TIMESTAMP_WIDTH-1:0] last_update_ts;
        logic [PRICE_WIDTH-1:0]     last_trade_px;
        logic [QTY_WIDTH-1:0]       last_trade_qty;
        logic                       valid;
    } book_entry_t;
    
    localparam int unsigned ENTRY_WIDTH = $bits(book_entry_t);
    
    //=========================================================================
    // Signal Declarations
    //=========================================================================
    
    // State machine
    typedef enum logic [2:0] {
        BOOK_IDLE,
        BOOK_READ,
        BOOK_PROCESS,
        BOOK_WRITE,
        BOOK_EMIT
    } book_state_e;
    
    book_state_e state;
    
    // Input registration
    itch_msg_t   msg_reg;
    logic        msg_pending;
    
    // Bank selection
    logic [BANK_IDX_WIDTH-1:0] current_bank;
    logic [BANK_ADDR_WIDTH-1:0] current_addr;
    logic [BANK_IDX_WIDTH-1:0] last_bank;
    logic                       bank_conflict;
    
    // BRAM interfaces (4 banks)
    logic [ENTRY_WIDTH-1:0]    bram_rd_data [NUM_BANKS];
    logic [ENTRY_WIDTH-1:0]    bram_wr_data [NUM_BANKS];
    logic [BANK_ADDR_WIDTH-1:0] bram_addr   [NUM_BANKS];
    logic                      bram_we     [NUM_BANKS];
    logic                      bram_en     [NUM_BANKS];
    
    // Current book entry
    book_entry_t current_entry;
    book_entry_t updated_entry;
    
    // Output event
    book_event_t event_reg;
    logic        event_pending;
    
    // Conflict FIFO
    logic        conflict_fifo_push;
    logic        conflict_fifo_pop;
    itch_msg_t   conflict_fifo_data;
    logic        conflict_fifo_empty;
    logic        conflict_fifo_full;
    logic [3:0]  conflict_fifo_level;
    
    // Pipeline control
    logic        pipeline_stall;
    
    //=========================================================================
    // BRAM Instantiation (4 banks)
    //=========================================================================
    
    generate
        for (genvar b = 0; b < NUM_BANKS; b++) begin : gen_banks
            // Simple dual-port BRAM
            logic [ENTRY_WIDTH-1:0] bram_mem [BANK_SIZE];
            
            always_ff @(posedge clk) begin
                if (bram_en[b]) begin
                    if (bram_we[b]) begin
                        bram_mem[bram_addr[b]] <= bram_wr_data[b];
                    end
                    bram_rd_data[b] <= bram_mem[bram_addr[b]];
                end
            end
            
            // Initialize to zero (for simulation)
            initial begin
                for (int i = 0; i < BANK_SIZE; i++) begin
                    bram_mem[i] = '0;
                end
            end
        end
    endgenerate
    
    //=========================================================================
    // Bank Selection Logic
    //=========================================================================
    
    // Bank = symbol_idx[1:0], Address = symbol_idx[IDX_WIDTH-1:2]
    assign current_bank = msg_reg.symbol_idx[BANK_IDX_WIDTH-1:0];
    assign current_addr = msg_reg.symbol_idx[IDX_WIDTH-1:BANK_IDX_WIDTH];
    
    // Bank conflict detection (same bank as previous cycle)
    assign bank_conflict = (state == BOOK_READ || state == BOOK_PROCESS || state == BOOK_WRITE) &&
                          (current_bank == last_bank);
    
    //=========================================================================
    // Conflict FIFO (for handling bank conflicts)
    //=========================================================================
    
    // Simple small FIFO for buffering conflicting requests
    logic [3:0] fifo_wr_ptr, fifo_rd_ptr;
    itch_msg_t  fifo_mem [16];
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
        end else begin
            if (conflict_fifo_push && !conflict_fifo_full) begin
                fifo_mem[fifo_wr_ptr] <= msg_reg;
                fifo_wr_ptr <= fifo_wr_ptr + 1;
            end
            
            if (conflict_fifo_pop && !conflict_fifo_empty) begin
                fifo_rd_ptr <= fifo_rd_ptr + 1;
            end
        end
    end
    
    assign conflict_fifo_data  = fifo_mem[fifo_rd_ptr];
    assign conflict_fifo_empty = (fifo_wr_ptr == fifo_rd_ptr);
    assign conflict_fifo_full  = (fifo_wr_ptr + 1 == fifo_rd_ptr);
    assign conflict_fifo_level = fifo_wr_ptr - fifo_rd_ptr;
    
    //=========================================================================
    // State Machine
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= BOOK_IDLE;
            msg_reg       <= '0;
            msg_pending   <= 1'b0;
            last_bank     <= '0;
            current_entry <= '0;
            updated_entry <= '0;
            event_reg     <= '0;
            event_pending <= 1'b0;
            
            for (int b = 0; b < NUM_BANKS; b++) begin
                bram_en[b] <= 1'b0;
                bram_we[b] <= 1'b0;
            end
        end else begin
            // Default: disable all BRAM operations
            for (int b = 0; b < NUM_BANKS; b++) begin
                bram_en[b] <= 1'b0;
                bram_we[b] <= 1'b0;
            end
            
            conflict_fifo_push <= 1'b0;
            conflict_fifo_pop  <= 1'b0;
            
            case (state)
                BOOK_IDLE: begin
                    event_pending <= 1'b0;
                    
                    if (cfg_enable && msg_valid && !msg_pending) begin
                        // Accept new message
                        msg_reg     <= msg_in;
                        msg_pending <= 1'b1;
                        
                        if (msg_in.symbol_valid && msg_in.is_book_update) begin
                            state <= BOOK_READ;
                        end else begin
                            // Invalid symbol or non-book message
                            state <= BOOK_EMIT;
                        end
                    end else if (!conflict_fifo_empty) begin
                        // Process from conflict FIFO
                        msg_reg     <= conflict_fifo_data;
                        msg_pending <= 1'b1;
                        conflict_fifo_pop <= 1'b1;
                        state <= BOOK_READ;
                    end
                end
                
                BOOK_READ: begin
                    // Check for bank conflict
                    if (bank_conflict && state != BOOK_READ) begin
                        // Push to conflict FIFO
                        conflict_fifo_push <= 1'b1;
                        msg_pending <= 1'b0;
                        state <= BOOK_IDLE;
                    end else begin
                        // Read current book entry from BRAM
                        bram_en[current_bank]   <= 1'b1;
                        bram_addr[current_bank] <= current_addr;
                        last_bank <= current_bank;
                        state <= BOOK_PROCESS;
                    end
                end
                
                BOOK_PROCESS: begin
                    // Current entry available from BRAM read
                    current_entry <= book_entry_t'(bram_rd_data[last_bank]);
                    
                    // Update book based on message type
                    updated_entry <= current_entry;
                    updated_entry.last_update_ts <= msg_reg.decode_ts;
                    updated_entry.valid <= 1'b1;
                    
                    case (msg_reg.msg_type)
                        ITCH_ADD_ORDER, ITCH_ADD_ORDER_MPID: begin
                            // Add order: update TOB if better price
                            if (msg_reg.side == SIDE_BID) begin
                                if (!current_entry.valid || 
                                    msg_reg.price > current_entry.bid_px ||
                                    current_entry.bid_qty == 0) begin
                                    updated_entry.bid_px  <= msg_reg.price;
                                    updated_entry.bid_qty <= msg_reg.qty;
                                end
                            end else begin
                                if (!current_entry.valid || 
                                    msg_reg.price < current_entry.ask_px ||
                                    current_entry.ask_qty == 0) begin
                                    updated_entry.ask_px  <= msg_reg.price;
                                    updated_entry.ask_qty <= msg_reg.qty;
                                end
                            end
                        end
                        
                        ITCH_ORDER_EXECUTED, ITCH_ORDER_EXECUTED_PX: begin
                            // Execution: reduce quantity (simplified - assumes at TOB)
                            // Real implementation would track orders by ID
                            if (msg_reg.side == SIDE_BID) begin
                                if (current_entry.bid_qty > msg_reg.qty) begin
                                    updated_entry.bid_qty <= current_entry.bid_qty - msg_reg.qty;
                                end else begin
                                    updated_entry.bid_qty <= '0;
                                end
                            end else begin
                                if (current_entry.ask_qty > msg_reg.qty) begin
                                    updated_entry.ask_qty <= current_entry.ask_qty - msg_reg.qty;
                                end else begin
                                    updated_entry.ask_qty <= '0;
                                end
                            end
                        end
                        
                        ITCH_ORDER_CANCEL: begin
                            // Cancel: reduce quantity
                            if (msg_reg.side == SIDE_BID) begin
                                if (current_entry.bid_qty > msg_reg.qty) begin
                                    updated_entry.bid_qty <= current_entry.bid_qty - msg_reg.qty;
                                end else begin
                                    updated_entry.bid_qty <= '0;
                                end
                            end else begin
                                if (current_entry.ask_qty > msg_reg.qty) begin
                                    updated_entry.ask_qty <= current_entry.ask_qty - msg_reg.qty;
                                end else begin
                                    updated_entry.ask_qty <= '0;
                                end
                            end
                        end
                        
                        ITCH_ORDER_DELETE: begin
                            // Delete: clear TOB (simplified)
                            if (msg_reg.side == SIDE_BID) begin
                                updated_entry.bid_qty <= '0;
                            end else begin
                                updated_entry.ask_qty <= '0;
                            end
                        end
                        
                        ITCH_ORDER_REPLACE: begin
                            // Replace: update price and quantity
                            if (msg_reg.side == SIDE_BID) begin
                                updated_entry.bid_px  <= msg_reg.price;
                                updated_entry.bid_qty <= msg_reg.qty;
                            end else begin
                                updated_entry.ask_px  <= msg_reg.price;
                                updated_entry.ask_qty <= msg_reg.qty;
                            end
                        end
                        
                        ITCH_TRADE: begin
                            // Trade: record last trade
                            updated_entry.last_trade_px  <= msg_reg.price;
                            updated_entry.last_trade_qty <= msg_reg.qty;
                        end
                        
                        default: begin
                            // No update
                        end
                    endcase
                    
                    state <= BOOK_WRITE;
                end
                
                BOOK_WRITE: begin
                    // Write updated entry back to BRAM
                    bram_en[last_bank]      <= 1'b1;
                    bram_we[last_bank]      <= 1'b1;
                    bram_addr[last_bank]    <= current_addr;
                    bram_wr_data[last_bank] <= updated_entry;
                    
                    state <= BOOK_EMIT;
                end
                
                BOOK_EMIT: begin
                    // Build output event
                    event_reg.ingress_ts       <= msg_reg.ingress_ts;
                    event_reg.book_ts          <= msg_reg.decode_ts;
                    event_reg.symbol_idx       <= msg_reg.symbol_idx;
                    event_reg.tob.bid_px       <= updated_entry.bid_px;
                    event_reg.tob.bid_qty      <= updated_entry.bid_qty;
                    event_reg.tob.ask_px       <= updated_entry.ask_px;
                    event_reg.tob.ask_qty      <= updated_entry.ask_qty;
                    event_reg.tob.last_update_ts <= updated_entry.last_update_ts;
                    event_reg.tob.valid        <= updated_entry.valid;
                    event_reg.last_trade_px    <= updated_entry.last_trade_px;
                    event_reg.last_trade_qty   <= updated_entry.last_trade_qty;
                    event_reg.tob_changed      <= 1'b1;
                    event_reg.trade_occurred   <= (msg_reg.msg_type == ITCH_TRADE);
                    event_reg.stale            <= msg_reg.stale;
                    event_reg.trigger_msg_type <= msg_reg.msg_type;
                    
                    event_pending <= 1'b1;
                    msg_pending   <= 1'b0;
                    
                    if (event_ready || !event_pending) begin
                        state <= BOOK_IDLE;
                    end
                end
            endcase
        end
    end
    
    //=========================================================================
    // Output Assignments
    //=========================================================================
    
    assign event_out   = event_reg;
    assign event_valid = event_pending && (state == BOOK_EMIT || state == BOOK_IDLE);
    
    // Ready when idle and no pending operation
    assign msg_ready = (state == BOOK_IDLE) && !msg_pending && !conflict_fifo_full && cfg_enable;
    
    //=========================================================================
    // Statistics
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_updates         <= '0;
            stat_bank_conflicts  <= '0;
            stat_invalid_symbols <= '0;
        end else begin
            if (event_valid && event_ready) begin
                stat_updates <= stat_updates + 1'b1;
            end
            
            if (conflict_fifo_push) begin
                stat_bank_conflicts <= stat_bank_conflicts + 1'b1;
            end
            
            if (msg_valid && msg_ready && !msg_in.symbol_valid) begin
                stat_invalid_symbols <= stat_invalid_symbols + 1'b1;
            end
        end
    end

endmodule : book_tob
