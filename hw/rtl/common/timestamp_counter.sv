//-----------------------------------------------------------------------------
// File: timestamp_counter.sv
// Description: Free-running 64-bit timestamp counter for latency measurement.
//              Includes latency histogram generation.
//
// Features:
//   - 64-bit counter at core_clk (300 MHz)
//   - Histogram with 256 bins for latency distribution
//   - Configurable bin width (cycles per bin)
//   - Overflow counting for out-of-range latencies
//
//-----------------------------------------------------------------------------

module timestamp_counter #(
    parameter int unsigned COUNTER_WIDTH = 64,
    parameter int unsigned HIST_BINS     = 256,
    parameter int unsigned HIST_WIDTH    = 32,
    parameter int unsigned BIN_SHIFT     = 2    // Cycles per bin = 2^BIN_SHIFT
) (
    input  logic                        clk,
    input  logic                        rst_n,
    
    //-------------------------------------------------------------------------
    // Timestamp Output
    //-------------------------------------------------------------------------
    output logic [COUNTER_WIDTH-1:0]    timestamp,
    
    //-------------------------------------------------------------------------
    // Latency Sample Input
    //-------------------------------------------------------------------------
    input  logic [COUNTER_WIDTH-1:0]    latency_start,
    input  logic [COUNTER_WIDTH-1:0]    latency_end,
    input  logic                        latency_valid,
    
    //-------------------------------------------------------------------------
    // Histogram Read Interface
    //-------------------------------------------------------------------------
    input  logic [7:0]                  hist_addr,
    input  logic                        hist_rd,
    output logic [HIST_WIDTH-1:0]       hist_data,
    
    //-------------------------------------------------------------------------
    // Configuration
    //-------------------------------------------------------------------------
    input  logic                        cfg_enable,
    input  logic                        cfg_hist_clear,
    
    //-------------------------------------------------------------------------
    // Statistics
    //-------------------------------------------------------------------------
    output logic [31:0]                 stat_samples,
    output logic [31:0]                 stat_overflow,
    output logic [COUNTER_WIDTH-1:0]   stat_min_latency,
    output logic [COUNTER_WIDTH-1:0]   stat_max_latency,
    output logic [COUNTER_WIDTH-1:0]   stat_sum_latency  // For average calculation
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    
    localparam int unsigned BIN_ADDR_WIDTH = $clog2(HIST_BINS);
    localparam int unsigned MAX_BIN_LATENCY = HIST_BINS << BIN_SHIFT;
    
    //=========================================================================
    // Signal Declarations
    //=========================================================================
    
    // Histogram memory
    logic [HIST_WIDTH-1:0] hist_mem [HIST_BINS];
    
    // Latency calculation
    logic [COUNTER_WIDTH-1:0] latency_delta;
    logic [BIN_ADDR_WIDTH-1:0] bin_idx;
    logic                      bin_valid;
    logic                      bin_overflow;
    
    // Pipeline registers
    logic                      sample_valid_d1;
    logic [BIN_ADDR_WIDTH-1:0] bin_idx_d1;
    logic                      overflow_d1;
    logic [COUNTER_WIDTH-1:0]  latency_d1;
    
    //=========================================================================
    // Timestamp Counter
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timestamp <= '0;
        end else if (cfg_enable) begin
            timestamp <= timestamp + 1'b1;
        end
    end
    
    //=========================================================================
    // Latency Calculation
    //=========================================================================
    
    // Calculate latency delta (handles wrap-around)
    assign latency_delta = latency_end - latency_start;
    
    // Calculate bin index
    assign bin_idx = latency_delta[BIN_SHIFT +: BIN_ADDR_WIDTH];
    assign bin_overflow = (latency_delta >= MAX_BIN_LATENCY);
    
    // Pipeline stage
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_valid_d1 <= 1'b0;
            bin_idx_d1      <= '0;
            overflow_d1     <= 1'b0;
            latency_d1      <= '0;
        end else begin
            sample_valid_d1 <= latency_valid && cfg_enable;
            bin_idx_d1      <= bin_idx;
            overflow_d1     <= bin_overflow;
            latency_d1      <= latency_delta;
        end
    end
    
    //=========================================================================
    // Histogram Update
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < HIST_BINS; i++) begin
                hist_mem[i] <= '0;
            end
        end else if (cfg_hist_clear) begin
            for (int i = 0; i < HIST_BINS; i++) begin
                hist_mem[i] <= '0;
            end
        end else if (sample_valid_d1 && !overflow_d1) begin
            // Increment histogram bin (saturating)
            if (hist_mem[bin_idx_d1] < {HIST_WIDTH{1'b1}}) begin
                hist_mem[bin_idx_d1] <= hist_mem[bin_idx_d1] + 1'b1;
            end
        end
    end
    
    // Histogram read
    always_ff @(posedge clk) begin
        if (hist_rd) begin
            hist_data <= hist_mem[hist_addr];
        end
    end
    
    //=========================================================================
    // Statistics
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_samples     <= '0;
            stat_overflow    <= '0;
            stat_min_latency <= {COUNTER_WIDTH{1'b1}};  // Start at max
            stat_max_latency <= '0;
            stat_sum_latency <= '0;
        end else if (cfg_hist_clear) begin
            stat_samples     <= '0;
            stat_overflow    <= '0;
            stat_min_latency <= {COUNTER_WIDTH{1'b1}};
            stat_max_latency <= '0;
            stat_sum_latency <= '0;
        end else if (sample_valid_d1) begin
            stat_samples <= stat_samples + 1'b1;
            
            if (overflow_d1) begin
                stat_overflow <= stat_overflow + 1'b1;
            end
            
            if (latency_d1 < stat_min_latency) begin
                stat_min_latency <= latency_d1;
            end
            
            if (latency_d1 > stat_max_latency) begin
                stat_max_latency <= latency_d1;
            end
            
            stat_sum_latency <= stat_sum_latency + latency_d1;
        end
    end

endmodule : timestamp_counter
