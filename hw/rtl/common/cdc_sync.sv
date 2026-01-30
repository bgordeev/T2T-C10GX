//-----------------------------------------------------------------------------
// File: cdc_sync.sv
// Description: Clock Domain Crossing (CDC) synchronizers for safe signal
//              transfer between asynchronous clock domains.
//
// Includes:
//   - Single-bit 2-FF synchronizer
//   - Multi-bit synchronizer with handshake
//   - Pulse synchronizer
//   - Reset synchronizer
//
//-----------------------------------------------------------------------------

//=============================================================================
// Single-bit 2-FF Synchronizer
//=============================================================================
module cdc_sync_single #(
    parameter int unsigned STAGES = 2,      // Number of synchronizer stages
    parameter logic        INIT_VAL = 1'b0  // Initial/reset value
) (
    input  logic clk,
    input  logic rst_n,
    input  logic async_in,
    output logic sync_out
);

    // Synchronizer chain
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    logic [STAGES-1:0] sync_chain;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_chain <= {STAGES{INIT_VAL}};
        end else begin
            sync_chain <= {sync_chain[STAGES-2:0], async_in};
        end
    end
    
    assign sync_out = sync_chain[STAGES-1];

endmodule : cdc_sync_single


//=============================================================================
// Multi-bit Synchronizer with Gray Encoding
//=============================================================================
module cdc_sync_bus #(
    parameter int unsigned WIDTH  = 8,
    parameter int unsigned STAGES = 2
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [WIDTH-1:0] async_in,   // Should be Gray-coded or single-bit changing
    output logic [WIDTH-1:0] sync_out
);

    // Synchronizer chains for each bit
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED" *)
    logic [WIDTH-1:0] sync_chain [STAGES];
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < STAGES; i++) begin
                sync_chain[i] <= '0;
            end
        end else begin
            sync_chain[0] <= async_in;
            for (int i = 1; i < STAGES; i++) begin
                sync_chain[i] <= sync_chain[i-1];
            end
        end
    end
    
    assign sync_out = sync_chain[STAGES-1];

endmodule : cdc_sync_bus


//=============================================================================
// Pulse Synchronizer (level-to-pulse, with handshake)
//=============================================================================
module cdc_sync_pulse (
    // Source domain
    input  logic src_clk,
    input  logic src_rst_n,
    input  logic src_pulse,      // Single-cycle pulse in source domain
    output logic src_busy,       // High while transfer in progress
    
    // Destination domain
    input  logic dst_clk,
    input  logic dst_rst_n,
    output logic dst_pulse       // Single-cycle pulse in destination domain
);

    // Source domain: toggle register
    logic src_toggle;
    logic src_ack_sync;
    
    // Destination domain
    logic dst_toggle_sync;
    logic dst_toggle_prev;
    logic dst_ack;
    
    //-------------------------------------------------------------------------
    // Source Domain Logic
    //-------------------------------------------------------------------------
    
    // Toggle on source pulse (when not busy)
    always_ff @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            src_toggle <= 1'b0;
        end else if (src_pulse && !src_busy) begin
            src_toggle <= ~src_toggle;
        end
    end
    
    // Synchronize ack back to source domain
    cdc_sync_single #(.STAGES(2)) u_ack_sync (
        .clk       (src_clk),
        .rst_n     (src_rst_n),
        .async_in  (dst_ack),
        .sync_out  (src_ack_sync)
    );
    
    // Busy until ack received (toggle matches ack)
    assign src_busy = (src_toggle != src_ack_sync);
    
    //-------------------------------------------------------------------------
    // Destination Domain Logic
    //-------------------------------------------------------------------------
    
    // Synchronize toggle to destination domain
    cdc_sync_single #(.STAGES(2)) u_toggle_sync (
        .clk       (dst_clk),
        .rst_n     (dst_rst_n),
        .async_in  (src_toggle),
        .sync_out  (dst_toggle_sync)
    );
    
    // Detect toggle change
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_toggle_prev <= 1'b0;
        end else begin
            dst_toggle_prev <= dst_toggle_sync;
        end
    end
    
    // Generate pulse on toggle change
    assign dst_pulse = (dst_toggle_sync != dst_toggle_prev);
    
    // Acknowledge (follows toggle)
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_ack <= 1'b0;
        end else begin
            dst_ack <= dst_toggle_sync;
        end
    end

endmodule : cdc_sync_pulse


//=============================================================================
// Reset Synchronizer (async assert, sync deassert)
//=============================================================================
module cdc_reset_sync #(
    parameter int unsigned STAGES = 3      // Extra stage for reset release
) (
    input  logic clk,
    input  logic async_rst_n,              // Asynchronous reset (active low)
    output logic sync_rst_n                // Synchronized reset (active low)
);

    // Reset synchronizer chain
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [STAGES-1:0] rst_chain;
    
    always_ff @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n) begin
            rst_chain <= '0;  // Async assert (immediate)
        end else begin
            rst_chain <= {rst_chain[STAGES-2:0], 1'b1};  // Sync deassert
        end
    end
    
    assign sync_rst_n = rst_chain[STAGES-1];

endmodule : cdc_reset_sync


//=============================================================================
// Handshake Synchronizer for Multi-bit Data
//=============================================================================
module cdc_sync_handshake #(
    parameter int unsigned WIDTH = 32
) (
    // Source domain
    input  logic             src_clk,
    input  logic             src_rst_n,
    input  logic [WIDTH-1:0] src_data,
    input  logic             src_valid,    // Data valid strobe
    output logic             src_ready,    // Ready for new data
    
    // Destination domain
    input  logic             dst_clk,
    input  logic             dst_rst_n,
    output logic [WIDTH-1:0] dst_data,
    output logic             dst_valid,    // Data valid (single cycle)
    input  logic             dst_ready     // Destination ready (can be tied high)
);

    // Source domain registers
    logic [WIDTH-1:0] src_data_reg;
    logic src_req;
    logic src_ack_sync;
    
    // Destination domain registers
    logic dst_req_sync;
    logic dst_req_prev;
    logic dst_ack;
    logic [WIDTH-1:0] dst_data_reg;
    
    //-------------------------------------------------------------------------
    // Source Domain
    //-------------------------------------------------------------------------
    
    // Capture data and assert request
    always_ff @(posedge src_clk or negedge src_rst_n) begin
        if (!src_rst_n) begin
            src_data_reg <= '0;
            src_req      <= 1'b0;
        end else if (src_valid && src_ready) begin
            src_data_reg <= src_data;
            src_req      <= ~src_req;  // Toggle
        end
    end
    
    // Ready when ack matches request
    assign src_ready = (src_req == src_ack_sync);
    
    // Synchronize ack
    cdc_sync_single #(.STAGES(2)) u_ack_sync (
        .clk       (src_clk),
        .rst_n     (src_rst_n),
        .async_in  (dst_ack),
        .sync_out  (src_ack_sync)
    );
    
    //-------------------------------------------------------------------------
    // Destination Domain
    //-------------------------------------------------------------------------
    
    // Synchronize request
    cdc_sync_single #(.STAGES(2)) u_req_sync (
        .clk       (dst_clk),
        .rst_n     (dst_rst_n),
        .async_in  (src_req),
        .sync_out  (dst_req_sync)
    );
    
    // Detect request change
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_req_prev <= 1'b0;
        end else begin
            dst_req_prev <= dst_req_sync;
        end
    end
    
    // Capture data on request edge
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_data_reg <= '0;
        end else if (dst_req_sync != dst_req_prev) begin
            dst_data_reg <= src_data_reg;  // Stable by now
        end
    end
    
    // Valid pulse
    assign dst_valid = (dst_req_sync != dst_req_prev);
    assign dst_data  = dst_data_reg;
    
    // Acknowledge (follows request when ready)
    always_ff @(posedge dst_clk or negedge dst_rst_n) begin
        if (!dst_rst_n) begin
            dst_ack <= 1'b0;
        end else if (dst_ready || !dst_valid) begin
            dst_ack <= dst_req_sync;
        end
    end

endmodule : cdc_sync_handshake
