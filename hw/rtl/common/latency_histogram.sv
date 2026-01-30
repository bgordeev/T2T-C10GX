//-----------------------------------------------------------------------------
// File: latency_histogram.sv
// Description: On-chip latency histogram for real-time performance monitoring.
//              Maintains per-stage latency distributions in BRAM bins.
//
// Features:
//   - 128 bins per stage (configurable bin width)
//   - Multiple stages: ingress→parser, parser→book, book→risk, end-to-end
//   - BRAM-backed counters for high-rate updates
//   - CSR-readable bin values for p50/p90/p99/p99.9 calculation
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module latency_histogram #(
    parameter int unsigned NUM_STAGES    = 4,     // Number of pipeline stages
    parameter int unsigned NUM_BINS      = 128,   // Bins per stage
    parameter int unsigned BIN_WIDTH     = 32,    // Counter width
    parameter int unsigned CYCLES_PER_BIN = 10    // Clock cycles per bin (granularity)
) (
    input  logic                    clk,
    input  logic                    rst_n,
    
    //-------------------------------------------------------------------------
    // Latency Sample Inputs (one per stage)
    //-------------------------------------------------------------------------
    input  logic [63:0]             sample_ts_start [NUM_STAGES],
    input  logic [63:0]             sample_ts_end   [NUM_STAGES],
    input  logic                    sample_valid    [NUM_STAGES],
    
    //-------------------------------------------------------------------------
    // Current Timestamp
    //-------------------------------------------------------------------------
    input  logic [63:0]             timestamp_cnt,
    
    //-------------------------------------------------------------------------
    // CSR Read Interface
    //-------------------------------------------------------------------------
    input  logic [7:0]              csr_addr,       // {stage[1:0], bin[6:0]}
    input  logic                    csr_rd,
    output logic [31:0]             csr_data,
    output logic                    csr_valid,
    
    //-------------------------------------------------------------------------
    // Control
    //-------------------------------------------------------------------------
    input  logic                    clear
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    
    localparam int unsigned STAGE_BITS = $clog2(NUM_STAGES);
    localparam int unsigned BIN_BITS   = $clog2(NUM_BINS);
    localparam int unsigned TOTAL_BINS = NUM_STAGES * NUM_BINS;
    
    //=========================================================================
    // Signal Declarations
    //=========================================================================
    
    // BRAM for histogram storage
    // Organized as: [stage][bin] -> count
    logic [BIN_WIDTH-1:0] hist_bram [TOTAL_BINS];
    
    // Sample processing
    logic [63:0] latency_cycles [NUM_STAGES];
    logic [BIN_BITS-1:0] bin_idx [NUM_STAGES];
    logic sample_pending [NUM_STAGES];
    
    // Arbitration for BRAM access
    logic [STAGE_BITS-1:0] arb_stage;
    logic arb_valid;
    logic [BIN_BITS-1:0] arb_bin;
    
    // BRAM access
    logic [$clog2(TOTAL_BINS)-1:0] bram_addr;
    logic bram_we;
    logic [BIN_WIDTH-1:0] bram_wdata;
    logic [BIN_WIDTH-1:0] bram_rdata;
    
    // CSR read pipeline
    logic csr_rd_d1;
    logic [7:0] csr_addr_d1;
    
    //=========================================================================
    // Latency Calculation and Bin Mapping
    //=========================================================================
    
    generate
        for (genvar s = 0; s < NUM_STAGES; s++) begin : gen_stages
            // Calculate latency in cycles
            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    latency_cycles[s] <= '0;
                    bin_idx[s]        <= '0;
                    sample_pending[s] <= 1'b0;
                end else begin
                    if (sample_valid[s]) begin
                        // Calculate latency
                        latency_cycles[s] <= sample_ts_end[s] - sample_ts_start[s];
                        
                        // Map to bin (saturate at max bin)
                        automatic logic [63:0] bin_raw;
                        bin_raw = (sample_ts_end[s] - sample_ts_start[s]) / CYCLES_PER_BIN;
                        
                        if (bin_raw >= NUM_BINS) begin
                            bin_idx[s] <= NUM_BINS - 1;  // Saturate
                        end else begin
                            bin_idx[s] <= bin_raw[BIN_BITS-1:0];
                        end
                        
                        sample_pending[s] <= 1'b1;
                    end else if (arb_valid && arb_stage == s[STAGE_BITS-1:0]) begin
                        sample_pending[s] <= 1'b0;
                    end
                end
            end
        end
    endgenerate
    
    //=========================================================================
    // Round-Robin Arbitration for BRAM Updates
    //=========================================================================
    
    logic [STAGE_BITS-1:0] rr_ptr;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_ptr    <= '0;
            arb_valid <= 1'b0;
            arb_stage <= '0;
            arb_bin   <= '0;
        end else begin
            arb_valid <= 1'b0;
            
            // Round-robin through stages looking for pending samples
            for (int i = 0; i < NUM_STAGES; i++) begin
                automatic int stage_check = (rr_ptr + i) % NUM_STAGES;
                
                if (sample_pending[stage_check] && !arb_valid) begin
                    arb_valid <= 1'b1;
                    arb_stage <= stage_check[STAGE_BITS-1:0];
                    arb_bin   <= bin_idx[stage_check];
                    rr_ptr    <= (stage_check + 1) % NUM_STAGES;
                end
            end
        end
    end
    
    //=========================================================================
    // BRAM Access Logic
    //=========================================================================
    
    // Read-modify-write for histogram update
    typedef enum logic [1:0] {
        HIST_IDLE,
        HIST_READ,
        HIST_WRITE
    } hist_state_e;
    
    hist_state_e hist_state;
    logic [STAGE_BITS-1:0] rmw_stage;
    logic [BIN_BITS-1:0] rmw_bin;
    logic [BIN_WIDTH-1:0] rmw_count;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hist_state <= HIST_IDLE;
            rmw_stage  <= '0;
            rmw_bin    <= '0;
            rmw_count  <= '0;
            bram_we    <= 1'b0;
        end else if (clear) begin
            // Clear all bins (would need counter, simplified here)
            hist_state <= HIST_IDLE;
            bram_we    <= 1'b0;
        end else begin
            bram_we <= 1'b0;
            
            case (hist_state)
                HIST_IDLE: begin
                    if (arb_valid && !csr_rd) begin
                        // Start read-modify-write
                        rmw_stage  <= arb_stage;
                        rmw_bin    <= arb_bin;
                        hist_state <= HIST_READ;
                    end
                end
                
                HIST_READ: begin
                    // Wait for BRAM read (1 cycle latency)
                    rmw_count  <= bram_rdata;
                    hist_state <= HIST_WRITE;
                end
                
                HIST_WRITE: begin
                    // Increment and write back
                    bram_we    <= 1'b1;
                    bram_wdata <= rmw_count + 1'b1;
                    hist_state <= HIST_IDLE;
                end
            endcase
        end
    end
    
    // BRAM address calculation
    always_comb begin
        if (csr_rd || csr_rd_d1) begin
            // CSR read takes priority
            bram_addr = csr_addr;
        end else if (hist_state == HIST_READ || hist_state == HIST_WRITE) begin
            // RMW operation
            bram_addr = {rmw_stage, rmw_bin};
        end else begin
            // Prepare for next arb
            bram_addr = {arb_stage, arb_bin};
        end
    end
    
    //=========================================================================
    // BRAM Instance
    //=========================================================================
    
    // Simple dual-port BRAM
    always_ff @(posedge clk) begin
        if (bram_we) begin
            hist_bram[bram_addr] <= bram_wdata;
        end
        bram_rdata <= hist_bram[bram_addr];
    end
    
    // Initialize BRAM to zero
    initial begin
        for (int i = 0; i < TOTAL_BINS; i++) begin
            hist_bram[i] = '0;
        end
    end
    
    //=========================================================================
    // CSR Read Interface
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_rd_d1   <= 1'b0;
            csr_addr_d1 <= '0;
            csr_data    <= '0;
            csr_valid   <= 1'b0;
        end else begin
            csr_rd_d1   <= csr_rd;
            csr_addr_d1 <= csr_addr;
            
            // Two-cycle read latency
            if (csr_rd_d1) begin
                csr_data  <= bram_rdata;
                csr_valid <= 1'b1;
            end else begin
                csr_valid <= 1'b0;
            end
        end
    end

endmodule : latency_histogram
