//-----------------------------------------------------------------------------
// File: pcie_dma.sv
// Description: PCIe DMA engine for transferring risk decisions to host memory.
//              Implements a ring buffer with producer/consumer semantics.
//
// Features:
//   - 64-byte record DMA (cache-line aligned)
//   - 64K entry ring buffer (4 MB)
//   - Polling or MSI-X notification
//   - Hardware producer index, software consumer index
//   - Full/empty detection with wrap-around
//
// Interface:
//   - AXI-Stream input from risk gate
//   - Avalon-MM master for PCIe BAR access
//   - PCIe Hard IP TLP interface (abstracted)
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module pcie_dma #(
    parameter int unsigned RING_DEPTH    = 65536,
    parameter int unsigned RECORD_BYTES  = 64,
    parameter int unsigned IDX_WIDTH     = $clog2(RING_DEPTH),
    parameter int unsigned ADDR_WIDTH    = 64,
    parameter int unsigned DATA_WIDTH    = 256   // PCIe data width (Gen2 x4)
) (
    input  logic                    clk,           // pcie_clk (125 MHz)
    input  logic                    rst_n,
    
    //-------------------------------------------------------------------------
    // Input: Risk Decisions (core_clk domain - CDC handled externally)
    //-------------------------------------------------------------------------
    input  risk_output_t            record_in,
    input  logic                    record_valid,
    output logic                    record_ready,
    
    //-------------------------------------------------------------------------
    // PCIe Avalon-MM Master (to Hard IP)
    //-------------------------------------------------------------------------
    output logic [ADDR_WIDTH-1:0]   pcie_address,
    output logic [DATA_WIDTH-1:0]   pcie_writedata,
    output logic [DATA_WIDTH/8-1:0] pcie_byteenable,
    output logic                    pcie_write,
    output logic                    pcie_read,
    input  logic [DATA_WIDTH-1:0]   pcie_readdata,
    input  logic                    pcie_waitrequest,
    input  logic                    pcie_readdatavalid,
    
    //-------------------------------------------------------------------------
    // MSI-X Interface
    //-------------------------------------------------------------------------
    output logic                    msix_irq,
    output logic [4:0]              msix_vector,
    input  logic                    msix_ack,
    
    //-------------------------------------------------------------------------
    // Configuration (from CSR)
    //-------------------------------------------------------------------------
    input  logic [63:0]             cfg_ring_base,       // Host physical address
    input  logic [IDX_WIDTH-1:0]    cfg_ring_size,       // Ring size (entries)
    input  logic                    cfg_enable,
    input  logic                    cfg_msix_enable,
    input  logic [15:0]             cfg_msix_threshold,  // IRQ after N records
    
    //-------------------------------------------------------------------------
    // Status (to CSR)
    //-------------------------------------------------------------------------
    output logic [IDX_WIDTH-1:0]    status_prod_idx,     // Producer index
    input  logic [IDX_WIDTH-1:0]    status_cons_idx,     // Consumer index (from host)
    output logic                    status_full,
    output logic                    status_empty,
    
    //-------------------------------------------------------------------------
    // Statistics
    //-------------------------------------------------------------------------
    output logic [31:0]             stat_records_dma,
    output logic [31:0]             stat_drops,
    output logic [31:0]             stat_irqs
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    
    localparam int unsigned RECORD_BITS = RECORD_BYTES * 8;
    
    //=========================================================================
    // Signal Declarations
    //=========================================================================
    
    // DMA state machine
    typedef enum logic [2:0] {
        DMA_IDLE,
        DMA_BUILD,
        DMA_WRITE_0,
        DMA_WRITE_1,
        DMA_WAIT,
        DMA_UPDATE_IDX
    } dma_state_e;
    
    dma_state_e state;
    
    // Ring buffer management
    logic [IDX_WIDTH-1:0] prod_idx;
    logic [IDX_WIDTH-1:0] cons_idx_sync;
    logic [IDX_WIDTH-1:0] next_prod_idx;
    logic                 ring_full;
    logic                 ring_empty;
    logic [IDX_WIDTH:0]   ring_level;
    
    // Record building
    dma_record_t          record_buf;
    logic [RECORD_BITS-1:0] record_packed;
    
    // DMA address calculation
    logic [63:0]          dma_addr;
    
    // MSI-X management
    logic [15:0]          records_since_irq;
    logic                 irq_pending;
    
    // Input FIFO (small buffer for CDC and burst absorption)
    logic                 fifo_push;
    logic                 fifo_pop;
    risk_output_t         fifo_data_in;
    risk_output_t         fifo_data_out;
    logic                 fifo_empty;
    logic                 fifo_full;
    logic [4:0]           fifo_level;
    
    // Small input FIFO
    risk_output_t         input_fifo [32];
    logic [4:0]           fifo_wr_ptr;
    logic [4:0]           fifo_rd_ptr;
    
    //=========================================================================
    // Input FIFO
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
        end else begin
            if (fifo_push && !fifo_full) begin
                input_fifo[fifo_wr_ptr] <= fifo_data_in;
                fifo_wr_ptr <= fifo_wr_ptr + 1;
            end
            
            if (fifo_pop && !fifo_empty) begin
                fifo_rd_ptr <= fifo_rd_ptr + 1;
            end
        end
    end
    
    assign fifo_data_out = input_fifo[fifo_rd_ptr];
    assign fifo_empty    = (fifo_wr_ptr == fifo_rd_ptr);
    assign fifo_full     = ((fifo_wr_ptr + 1) == fifo_rd_ptr);
    assign fifo_level    = fifo_wr_ptr - fifo_rd_ptr;
    
    assign fifo_push     = record_valid && !fifo_full && cfg_enable;
    assign fifo_data_in  = record_in;
    assign record_ready  = !fifo_full && cfg_enable;
    
    //=========================================================================
    // Ring Buffer Management
    //=========================================================================
    
    // Synchronize consumer index from host (written via CSR)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cons_idx_sync <= '0;
        end else begin
            cons_idx_sync <= status_cons_idx;
        end
    end
    
    // Calculate next producer index
    assign next_prod_idx = (prod_idx + 1) & (cfg_ring_size - 1);
    
    // Full/empty detection
    assign ring_full  = (next_prod_idx == cons_idx_sync);
    assign ring_empty = (prod_idx == cons_idx_sync);
    assign ring_level = prod_idx - cons_idx_sync;
    
    // Calculate DMA address for current record
    assign dma_addr = cfg_ring_base + (prod_idx * RECORD_BYTES);
    
    //=========================================================================
    // Record Building
    //=========================================================================
    
    // Build DMA record from risk output
    always_comb begin
        record_buf = '0;
        
        record_buf.seq        = fifo_data_out.book_event.symbol_idx;  // Simplified
        record_buf.ts_ing     = fifo_data_out.book_event.ingress_ts;
        record_buf.ts_dec     = fifo_data_out.decision_ts;
        record_buf.sym_idx    = fifo_data_out.book_event.symbol_idx;
        record_buf.side       = {7'b0, fifo_data_out.book_event.tob.valid};
        record_buf.flags      = {2'b0, 
                                 fifo_data_out.reason == RISK_KILL_SWITCH,
                                 fifo_data_out.reason == RISK_POSITION_LIMIT,
                                 fifo_data_out.reason == RISK_TOKEN_BUCKET,
                                 fifo_data_out.reason == RISK_PRICE_BAND,
                                 fifo_data_out.book_event.stale,
                                 fifo_data_out.accept};
        record_buf.qty        = fifo_data_out.book_event.tob.bid_qty;
        record_buf.price      = fifo_data_out.book_event.tob.bid_px;
        record_buf.ref_px     = fifo_data_out.book_event.tob.ask_px;
        record_buf.feature0   = fifo_data_out.book_event.tob.ask_px - 
                               fifo_data_out.book_event.tob.bid_px;  // Spread
        record_buf.feature1   = fifo_data_out.book_event.tob.bid_qty - 
                               fifo_data_out.book_event.tob.ask_qty;  // Imbalance
        record_buf.feature2   = fifo_data_out.book_event.last_trade_px;
    end
    
    assign record_packed = record_buf;
    
    //=========================================================================
    // DMA State Machine
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= DMA_IDLE;
            prod_idx         <= '0;
            pcie_write       <= 1'b0;
            pcie_read        <= 1'b0;
            pcie_address     <= '0;
            pcie_writedata   <= '0;
            pcie_byteenable  <= '0;
            msix_irq         <= 1'b0;
            msix_vector      <= '0;
            records_since_irq <= '0;
            irq_pending      <= 1'b0;
            fifo_pop         <= 1'b0;
        end else begin
            fifo_pop   <= 1'b0;
            pcie_write <= 1'b0;
            msix_irq   <= 1'b0;
            
            case (state)
                DMA_IDLE: begin
                    if (!fifo_empty && !ring_full && cfg_enable) begin
                        state <= DMA_BUILD;
                    end else if (fifo_empty && irq_pending && cfg_msix_enable) begin
                        // Send pending interrupt when idle
                        msix_irq   <= 1'b1;
                        msix_vector <= 5'd0;
                        irq_pending <= 1'b0;
                    end
                end
                
                DMA_BUILD: begin
                    // Record is already built combinationally
                    state <= DMA_WRITE_0;
                end
                
                DMA_WRITE_0: begin
                    // Write first 32 bytes
                    pcie_address    <= dma_addr;
                    pcie_writedata  <= record_packed[255:0];
                    pcie_byteenable <= {32{1'b1}};
                    pcie_write      <= 1'b1;
                    
                    if (!pcie_waitrequest) begin
                        state <= DMA_WRITE_1;
                    end
                end
                
                DMA_WRITE_1: begin
                    // Write second 32 bytes
                    pcie_address    <= dma_addr + 32;
                    pcie_writedata  <= record_packed[511:256];
                    pcie_byteenable <= {32{1'b1}};
                    pcie_write      <= 1'b1;
                    
                    if (!pcie_waitrequest) begin
                        state    <= DMA_UPDATE_IDX;
                        fifo_pop <= 1'b1;
                    end
                end
                
                DMA_UPDATE_IDX: begin
                    // Update producer index
                    prod_idx          <= next_prod_idx;
                    records_since_irq <= records_since_irq + 1;
                    
                    // Check if we should trigger interrupt
                    if (records_since_irq >= cfg_msix_threshold - 1) begin
                        irq_pending       <= 1'b1;
                        records_since_irq <= '0;
                    end
                    
                    state <= DMA_IDLE;
                end
                
                default: state <= DMA_IDLE;
            endcase
            
            // Handle MSI-X acknowledgment
            if (msix_ack) begin
                irq_pending <= 1'b0;
            end
        end
    end
    
    //=========================================================================
    // Status Outputs
    //=========================================================================
    
    assign status_prod_idx = prod_idx;
    assign status_full     = ring_full;
    assign status_empty    = ring_empty;
    
    //=========================================================================
    // Statistics
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_records_dma <= '0;
            stat_drops       <= '0;
            stat_irqs        <= '0;
        end else begin
            if (state == DMA_UPDATE_IDX) begin
                stat_records_dma <= stat_records_dma + 1'b1;
            end
            
            if (record_valid && ring_full) begin
                stat_drops <= stat_drops + 1'b1;
            end
            
            if (msix_irq) begin
                stat_irqs <= stat_irqs + 1'b1;
            end
        end
    end

endmodule : pcie_dma
