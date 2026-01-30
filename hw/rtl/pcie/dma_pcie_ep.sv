//-----------------------------------------------------------------------------
// File: dma_pcie_ep.sv
// Description: PCIe DMA endpoint for Gen2 x4 on Intel Cyclone 10 GX.
//              Implements ring buffer DMA with MSI-X support.
//
// Features:
//   - 64-byte record DMA to host hugepage rings
//   - Producer/consumer index management
//   - MSI-X interrupt support (optional, polled mode primary)
//   - Back-pressure handling with watermark
//   - Sequence number and CRC integrity
//
// Note: This module wraps Intel PCIe Hard IP. The actual Hard IP
//       instantiation is done in the Quartus project with Platform Designer.
//       This module provides the application-layer logic.
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module dma_pcie_ep #(
    parameter int unsigned RING_DEPTH     = 65536,
    parameter int unsigned RECORD_BYTES   = 64,
    parameter int unsigned WATERMARK      = 64     // Back-pressure threshold
) (
    input  logic                    clk,           // PCIe user clock (125 MHz)
    input  logic                    rst_n,
    
    //-------------------------------------------------------------------------
    // Risk Decision Input (to be DMA'd to host)
    //-------------------------------------------------------------------------
    input  risk_output_t            record_in,
    input  logic                    record_valid,
    output logic                    record_ready,
    
    //-------------------------------------------------------------------------
    // Ring Buffer Configuration (from CSR)
    //-------------------------------------------------------------------------
    input  logic [63:0]             ring_base_addr,
    input  logic [15:0]             ring_length,
    input  logic [15:0]             cons_idx_shadow,  // Host-written consumer index
    
    //-------------------------------------------------------------------------
    // Ring Buffer Status (to CSR)
    //-------------------------------------------------------------------------
    output logic [15:0]             prod_idx,
    output logic                    ring_full,
    output logic                    ring_overflow,
    
    //-------------------------------------------------------------------------
    // Avalon-MM Master Interface (to PCIe TX Bridge)
    //-------------------------------------------------------------------------
    output logic [63:0]             avm_address,
    output logic                    avm_write,
    output logic [511:0]            avm_writedata,    // 64 bytes = 512 bits
    output logic [63:0]             avm_byteenable,
    input  logic                    avm_waitrequest,
    
    //-------------------------------------------------------------------------
    // MSI-X Interface
    //-------------------------------------------------------------------------
    input  logic [31:0]             msix_cfg,
    output logic                    msix_req,
    output logic [2:0]              msix_vector,
    input  logic                    msix_ack,
    
    //-------------------------------------------------------------------------
    // Timestamp Input
    //-------------------------------------------------------------------------
    input  logic [63:0]             timestamp_cnt,
    
    //-------------------------------------------------------------------------
    // Statistics
    //-------------------------------------------------------------------------
    output logic [31:0]             stat_dma_writes,
    output logic [31:0]             stat_dma_stalls,
    output logic [31:0]             stat_ring_overflows
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    
    localparam int unsigned IDX_WIDTH = $clog2(RING_DEPTH);
    localparam int unsigned MSIX_COALESCE_CNT = 64;  // Coalesce MSI-X every N records
    
    //=========================================================================
    // Signal Declarations
    //=========================================================================
    
    // Ring buffer pointers
    logic [IDX_WIDTH-1:0] prod_idx_reg;
    logic [IDX_WIDTH-1:0] cons_idx_sync;
    logic [IDX_WIDTH:0]   free_slots;
    
    // State machine
    typedef enum logic [1:0] {
        DMA_IDLE,
        DMA_BUILD,
        DMA_WRITE,
        DMA_WAIT
    } dma_state_e;
    
    dma_state_e state;
    
    // Record building
    dma_record_t record_build;
    logic [511:0] record_packed;
    
    // MSI-X coalescing
    logic [7:0]  msix_coalesce_cnt;
    logic        msix_pending;
    
    // CRC calculation
    logic [15:0] record_crc;
    
    // Consumer index synchronization (cross-domain from CSR clock)
    logic [IDX_WIDTH-1:0] cons_idx_sync1, cons_idx_sync2;
    
    //=========================================================================
    // Consumer Index Synchronization
    //=========================================================================
    
    // Synchronize consumer index from CSR domain
    // Assumes cons_idx_shadow is updated atomically by host
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cons_idx_sync1 <= '0;
            cons_idx_sync2 <= '0;
            cons_idx_sync  <= '0;
        end else begin
            cons_idx_sync1 <= cons_idx_shadow[IDX_WIDTH-1:0];
            cons_idx_sync2 <= cons_idx_sync1;
            cons_idx_sync  <= cons_idx_sync2;
        end
    end
    
    //=========================================================================
    // Free Slots Calculation
    //=========================================================================
    
    // free_slots = (cons_idx - prod_idx - 1) mod ring_length
    // Using power-of-2 ring size for efficient modulo
    always_comb begin
        if (cons_idx_sync >= prod_idx_reg) begin
            free_slots = {1'b0, cons_idx_sync} - {1'b0, prod_idx_reg};
        end else begin
            free_slots = {1'b0, ring_length[IDX_WIDTH-1:0]} - 
                        ({1'b0, prod_idx_reg} - {1'b0, cons_idx_sync});
        end
        
        // Reserve one slot to distinguish full from empty
        if (free_slots > 0) begin
            free_slots = free_slots - 1;
        end
    end
    
    assign ring_full = (free_slots < WATERMARK);
    
    //=========================================================================
    // CRC-16 Calculation (simplified)
    //=========================================================================
    
    // Simple CRC-16 for record integrity
    function automatic logic [15:0] calc_crc16(input logic [447:0] data);
        logic [15:0] crc;
        crc = 16'hFFFF;
        for (int i = 0; i < 448; i++) begin
            crc = {crc[14:0], 1'b0} ^ (data[i] ? 16'h1021 : 16'h0000);
        end
        return crc;
    endfunction
    
    //=========================================================================
    // State Machine
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= DMA_IDLE;
            prod_idx_reg    <= '0;
            record_build    <= '0;
            ring_overflow   <= 1'b0;
            msix_coalesce_cnt <= '0;
            msix_pending    <= 1'b0;
            msix_req        <= 1'b0;
        end else begin
            // Default: clear single-cycle signals
            msix_req <= 1'b0;
            
            case (state)
                DMA_IDLE: begin
                    if (record_valid && record_ready) begin
                        // Build DMA record from risk output
                        record_build.seq         <= record_in.book_event.ingress_ts[31:0];
                        record_build.reserved_lo <= '0;
                        record_build.ts_ing      <= record_in.book_event.ingress_ts;
                        record_build.ts_dec      <= record_in.decision_ts;
                        record_build.sym_idx     <= record_in.book_event.symbol_idx;
                        record_build.side        <= {7'b0, record_in.book_event.trigger_msg_type == ITCH_ADD_ORDER ? 
                                                    (record_in.book_event.tob.bid_qty > 0 ? 1'b0 : 1'b1) : 1'b0};
                        record_build.flags       <= {2'b0, 
                                                    record_in.reason == RISK_KILL_SWITCH,
                                                    record_in.reason == RISK_POSITION_LIMIT,
                                                    record_in.reason == RISK_TOKEN_BUCKET,
                                                    record_in.reason == RISK_PRICE_BAND,
                                                    record_in.book_event.stale,
                                                    record_in.accept};
                        record_build.qty         <= record_in.book_event.tob.bid_qty;
                        record_build.price       <= record_in.book_event.tob.bid_px;
                        record_build.ref_px      <= record_in.book_event.tob.ask_px;
                        record_build.feature0    <= record_in.book_event.tob.ask_px - 
                                                   record_in.book_event.tob.bid_px;  // Spread
                        record_build.feature1    <= record_in.book_event.tob.bid_qty - 
                                                   record_in.book_event.tob.ask_qty;  // Imbalance
                        record_build.feature2    <= record_in.book_event.last_trade_px;
                        record_build.pad         <= '0;
                        record_build.reserved_hi <= '0;
                        
                        state <= DMA_BUILD;
                    end
                end
                
                DMA_BUILD: begin
                    // Calculate CRC over record (excluding CRC field itself)
                    record_build.payload_crc16 <= calc_crc16(record_packed[511:64]);
                    state <= DMA_WRITE;
                end
                
                DMA_WRITE: begin
                    if (!avm_waitrequest) begin
                        // Advance producer index
                        if (prod_idx_reg >= ring_length[IDX_WIDTH-1:0] - 1) begin
                            prod_idx_reg <= '0;
                        end else begin
                            prod_idx_reg <= prod_idx_reg + 1;
                        end
                        
                        // MSI-X coalescing
                        if (msix_coalesce_cnt >= MSIX_COALESCE_CNT - 1) begin
                            msix_coalesce_cnt <= '0;
                            msix_pending      <= 1'b1;
                        end else begin
                            msix_coalesce_cnt <= msix_coalesce_cnt + 1;
                        end
                        
                        state <= DMA_WAIT;
                    end
                end
                
                DMA_WAIT: begin
                    // Single cycle wait for pipeline
                    // Issue MSI-X if pending and enabled
                    if (msix_pending && msix_cfg[0]) begin
                        msix_req     <= 1'b1;
                        msix_vector  <= msix_cfg[10:8];
                        msix_pending <= 1'b0;
                    end
                    
                    state <= DMA_IDLE;
                end
            endcase
            
            // Overflow detection
            if (record_valid && !record_ready) begin
                ring_overflow <= 1'b1;
            end
        end
    end
    
    //=========================================================================
    // Record Packing
    //=========================================================================
    
    // Pack record structure into 512-bit vector (64 bytes)
    assign record_packed = {
        record_build.reserved_hi,      // Bytes 56-63
        record_build.pad,              // Bytes 54-55
        record_build.payload_crc16,    // Bytes 52-53
        record_build.feature2,         // Bytes 48-51
        record_build.feature1,         // Bytes 44-47
        record_build.feature0,         // Bytes 40-43
        record_build.ref_px,           // Bytes 36-39
        record_build.price,            // Bytes 32-35
        record_build.qty,              // Bytes 28-31
        record_build.flags,            // Byte 27
        record_build.side,             // Byte 26
        record_build.sym_idx,          // Bytes 24-25
        record_build.ts_dec,           // Bytes 16-23
        record_build.ts_ing,           // Bytes 8-15
        record_build.reserved_lo,      // Bytes 4-7
        record_build.seq               // Bytes 0-3
    };
    
    //=========================================================================
    // Avalon-MM Master Interface
    //=========================================================================
    
    // Calculate DMA address: ring_base + (prod_idx * 64)
    assign avm_address    = ring_base_addr + ({48'b0, prod_idx_reg} << 6);
    assign avm_write      = (state == DMA_WRITE);
    assign avm_writedata  = record_packed;
    assign avm_byteenable = 64'hFFFFFFFFFFFFFFFF;  // All bytes valid
    
    //=========================================================================
    // Output Assignments
    //=========================================================================
    
    assign prod_idx     = prod_idx_reg;
    assign record_ready = (state == DMA_IDLE) && !ring_full;
    
    //=========================================================================
    // Statistics
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_dma_writes     <= '0;
            stat_dma_stalls     <= '0;
            stat_ring_overflows <= '0;
        end else begin
            if (state == DMA_WRITE && !avm_waitrequest) begin
                stat_dma_writes <= stat_dma_writes + 1'b1;
            end
            
            if (record_valid && ring_full) begin
                stat_dma_stalls <= stat_dma_stalls + 1'b1;
            end
            
            if (record_valid && !record_ready) begin
                stat_ring_overflows <= stat_ring_overflows + 1'b1;
            end
        end
    end

endmodule : dma_pcie_ep
