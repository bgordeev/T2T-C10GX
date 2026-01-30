//-----------------------------------------------------------------------------
// File: axi_async_fifo.sv
// Description: Asynchronous FIFO with AXI-Stream interface for clock domain
//              crossing. Uses Gray code pointers for safe CDC.
//
// Parameters:
//   DATA_WIDTH - Width of TDATA
//   DEPTH      - FIFO depth (must be power of 2)
//   USER_WIDTH - Width of TUSER sideband
//
// Features:
//   - Full AXI-Stream handshaking (TVALID/TREADY)
//   - Gray code pointer synchronization
//   - Near-full/near-empty flags for flow control
//   - Overflow/underflow detection (sticky flags)
//
//-----------------------------------------------------------------------------

module axi_async_fifo #(
    parameter int unsigned DATA_WIDTH = 64,
    parameter int unsigned DEPTH      = 64,
    parameter int unsigned USER_WIDTH = 72,
    parameter int unsigned KEEP_WIDTH = DATA_WIDTH / 8,
    // Derived parameters
    localparam int unsigned ADDR_WIDTH = $clog2(DEPTH)
) (
    //-------------------------------------------------------------------------
    // Write side (producer clock domain)
    //-------------------------------------------------------------------------
    input  logic                    wr_clk,
    input  logic                    wr_rst_n,
    
    // AXI-Stream slave interface
    input  logic [DATA_WIDTH-1:0]   s_axis_tdata,
    input  logic [KEEP_WIDTH-1:0]   s_axis_tkeep,
    input  logic                    s_axis_tlast,
    input  logic [USER_WIDTH-1:0]   s_axis_tuser,
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    
    // Write-side status
    output logic [ADDR_WIDTH:0]     wr_level,      // Fill level (write domain)
    output logic                    wr_almost_full,
    output logic                    wr_overflow,   // Sticky overflow flag
    
    //-------------------------------------------------------------------------
    // Read side (consumer clock domain)
    //-------------------------------------------------------------------------
    input  logic                    rd_clk,
    input  logic                    rd_rst_n,
    
    // AXI-Stream master interface
    output logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output logic [KEEP_WIDTH-1:0]   m_axis_tkeep,
    output logic                    m_axis_tlast,
    output logic [USER_WIDTH-1:0]   m_axis_tuser,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    
    // Read-side status
    output logic [ADDR_WIDTH:0]     rd_level,      // Fill level (read domain)
    output logic                    rd_almost_empty,
    output logic                    rd_underflow   // Sticky underflow flag
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    
    localparam int unsigned TOTAL_WIDTH = DATA_WIDTH + KEEP_WIDTH + 1 + USER_WIDTH;
    localparam int unsigned ALMOST_FULL_THRESH = DEPTH - 4;
    localparam int unsigned ALMOST_EMPTY_THRESH = 4;
    
    //=========================================================================
    // Signal Declarations
    //=========================================================================
    
    // Memory array
    logic [TOTAL_WIDTH-1:0] mem [DEPTH];
    
    // Write pointer (binary and Gray)
    logic [ADDR_WIDTH:0] wr_ptr_bin;
    logic [ADDR_WIDTH:0] wr_ptr_gray;
    logic [ADDR_WIDTH:0] wr_ptr_gray_sync1;
    logic [ADDR_WIDTH:0] wr_ptr_gray_sync2;
    
    // Read pointer (binary and Gray)
    logic [ADDR_WIDTH:0] rd_ptr_bin;
    logic [ADDR_WIDTH:0] rd_ptr_gray;
    logic [ADDR_WIDTH:0] rd_ptr_gray_sync1;
    logic [ADDR_WIDTH:0] rd_ptr_gray_sync2;
    
    // Synchronized pointers (converted back to binary)
    logic [ADDR_WIDTH:0] rd_ptr_bin_wr_domain;
    logic [ADDR_WIDTH:0] wr_ptr_bin_rd_domain;
    
    // Control signals
    logic wr_en;
    logic rd_en;
    logic full;
    logic empty;
    
    // Packed data for storage
    logic [TOTAL_WIDTH-1:0] wr_data_packed;
    logic [TOTAL_WIDTH-1:0] rd_data_packed;
    
    //=========================================================================
    // Gray Code Conversion Functions
    //=========================================================================
    
    function automatic logic [ADDR_WIDTH:0] bin2gray(input logic [ADDR_WIDTH:0] bin);
        return bin ^ (bin >> 1);
    endfunction
    
    function automatic logic [ADDR_WIDTH:0] gray2bin(input logic [ADDR_WIDTH:0] gray);
        logic [ADDR_WIDTH:0] bin;
        bin[ADDR_WIDTH] = gray[ADDR_WIDTH];
        for (int i = ADDR_WIDTH - 1; i >= 0; i--) begin
            bin[i] = bin[i+1] ^ gray[i];
        end
        return bin;
    endfunction
    
    //=========================================================================
    // Write Side Logic
    //=========================================================================
    
    // Pack data for storage
    assign wr_data_packed = {s_axis_tuser, s_axis_tlast, s_axis_tkeep, s_axis_tdata};
    
    // Write enable when valid data and not full
    assign wr_en = s_axis_tvalid && s_axis_tready;
    
    // Ready when not full
    assign s_axis_tready = ~full;
    
    // Write pointer management
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_ptr_bin  <= '0;
            wr_ptr_gray <= '0;
        end else if (wr_en) begin
            wr_ptr_bin  <= wr_ptr_bin + 1'b1;
            wr_ptr_gray <= bin2gray(wr_ptr_bin + 1'b1);
        end
    end
    
    // Memory write
    always_ff @(posedge wr_clk) begin
        if (wr_en) begin
            mem[wr_ptr_bin[ADDR_WIDTH-1:0]] <= wr_data_packed;
        end
    end
    
    // Synchronize read pointer to write domain (2-FF synchronizer)
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_ptr_gray_sync1 <= '0;
            rd_ptr_gray_sync2 <= '0;
        end else begin
            rd_ptr_gray_sync1 <= rd_ptr_gray;
            rd_ptr_gray_sync2 <= rd_ptr_gray_sync1;
        end
    end
    
    // Convert synchronized Gray pointer back to binary
    assign rd_ptr_bin_wr_domain = gray2bin(rd_ptr_gray_sync2);
    
    // Full detection (write domain)
    // Full when write pointer is one complete cycle ahead of read pointer
    assign full = (wr_ptr_bin[ADDR_WIDTH] != rd_ptr_bin_wr_domain[ADDR_WIDTH]) &&
                  (wr_ptr_bin[ADDR_WIDTH-1:0] == rd_ptr_bin_wr_domain[ADDR_WIDTH-1:0]);
    
    // Calculate fill level (write domain)
    assign wr_level = wr_ptr_bin - rd_ptr_bin_wr_domain;
    
    // Almost full flag
    assign wr_almost_full = (wr_level >= ALMOST_FULL_THRESH);
    
    // Overflow detection (sticky)
    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_overflow <= 1'b0;
        end else if (s_axis_tvalid && full) begin
            wr_overflow <= 1'b1;  // Sticky - only cleared by reset
        end
    end
    
    //=========================================================================
    // Read Side Logic
    //=========================================================================
    
    // Read enable when not empty and downstream ready
    assign rd_en = m_axis_tvalid && m_axis_tready;
    
    // Valid when not empty
    assign m_axis_tvalid = ~empty;
    
    // Read pointer management
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_ptr_bin  <= '0;
            rd_ptr_gray <= '0;
        end else if (rd_en) begin
            rd_ptr_bin  <= rd_ptr_bin + 1'b1;
            rd_ptr_gray <= bin2gray(rd_ptr_bin + 1'b1);
        end
    end
    
    // Memory read (registered output for timing)
    always_ff @(posedge rd_clk) begin
        rd_data_packed <= mem[rd_ptr_bin[ADDR_WIDTH-1:0]];
    end
    
    // Unpack read data
    assign {m_axis_tuser, m_axis_tlast, m_axis_tkeep, m_axis_tdata} = rd_data_packed;
    
    // Synchronize write pointer to read domain (2-FF synchronizer)
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_ptr_gray_sync1 <= '0;
            wr_ptr_gray_sync2 <= '0;
        end else begin
            wr_ptr_gray_sync1 <= wr_ptr_gray;
            wr_ptr_gray_sync2 <= wr_ptr_gray_sync1;
        end
    end
    
    // Convert synchronized Gray pointer back to binary
    assign wr_ptr_bin_rd_domain = gray2bin(wr_ptr_gray_sync2);
    
    // Empty detection (read domain)
    assign empty = (rd_ptr_bin == wr_ptr_bin_rd_domain);
    
    // Calculate fill level (read domain)
    assign rd_level = wr_ptr_bin_rd_domain - rd_ptr_bin;
    
    // Almost empty flag
    assign rd_almost_empty = (rd_level <= ALMOST_EMPTY_THRESH);
    
    // Underflow detection (sticky)
    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_underflow <= 1'b0;
        end else if (m_axis_tready && empty) begin
            rd_underflow <= 1'b1;  // Sticky - only cleared by reset
        end
    end

    //=========================================================================
    // Assertions (for simulation)
    //=========================================================================
    
    `ifdef SIMULATION
    // synopsys translate_off
    
    // Check that depth is power of 2
    initial begin
        assert ((DEPTH & (DEPTH - 1)) == 0) 
            else $error("DEPTH must be a power of 2");
    end
    
    // Overflow should never happen if backpressure is working
    always @(posedge wr_clk) begin
        if (wr_rst_n && s_axis_tvalid && full) begin
            $warning("Async FIFO overflow detected!");
        end
    end
    
    // Underflow check
    always @(posedge rd_clk) begin
        if (rd_rst_n && m_axis_tready && empty) begin
            $warning("Async FIFO underflow detected!");
        end
    end
    
    // synopsys translate_on
    `endif

endmodule : axi_async_fifo
