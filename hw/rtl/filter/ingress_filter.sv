// ============================================================================
// Module: ingress_filter.sv
// Description: Ingress filter - multicast address filtering and timestamping
//              Drops frames not matching configured destination MAC
//              Injects high-resolution ingress timestamp
// ============================================================================

module ingress_filter #(
    parameter DATA_WIDTH = 64,
    parameter KEEP_WIDTH = 8
)(
    input  logic                    clk,
    input  logic                    rst_n,
    
    // AXI-Stream input (from CDC FIFO)
    input  logic [DATA_WIDTH-1:0]   s_axis_tdata,
    input  logic [KEEP_WIDTH-1:0]   s_axis_tkeep,
    input  logic                    s_axis_tvalid,
    output logic                    s_axis_tready,
    input  logic                    s_axis_tlast,
    input  logic [47:0]             s_axis_tuser,   // Timestamp from MAC
    
    // AXI-Stream output (to parser)
    output logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output logic [KEEP_WIDTH-1:0]   m_axis_tkeep,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic                    m_axis_tlast,
    output logic [47:0]             m_axis_tuser,   // Timestamp
    
    // CSR interface
    input  logic [47:0]             cfg_dst_mac,    // Expected destination MAC
    
    // Statistics
    output logic [31:0]             drop_count,
    output logic [31:0]             accept_count
);

// ============================================================================
// Timestamp counter - free-running nanosecond counter
// Increments every clock cycle (3.5 ns @ 285 MHz)
// ============================================================================
logic [47:0] timestamp_counter;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        timestamp_counter <= 48'h0;
    else
        timestamp_counter <= timestamp_counter + 48'd4;  // ~3.5 ns per cycle
end

// ============================================================================
// Frame state machine
// ============================================================================
typedef enum logic [1:0] {
    ST_IDLE,
    ST_FORWARD,     // Forwarding accepted frame
    ST_DROP         // Dropping rejected frame
} state_t;

state_t state;

// Capture timestamp on first beat
logic [47:0] frame_timestamp;
logic frame_accepted;

// Extract destination MAC from first beat
// In Ethernet frame: bytes 0-5 are destination MAC
// With 64-bit bus: dst_mac is in tdata[47:0] (assuming big-endian)
logic [47:0] dst_mac;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state           <= ST_IDLE;
        frame_timestamp <= 48'h0;
        frame_accepted  <= 1'b0;
        
        m_axis_tdata    <= '0;
        m_axis_tkeep    <= '0;
        m_axis_tvalid   <= 1'b0;
        m_axis_tlast    <= 1'b0;
        m_axis_tuser    <= 48'h0;
        
        drop_count      <= 32'h0;
        accept_count    <= 32'h0;
        
    end else begin
        case (state)
            ST_IDLE: begin
                m_axis_tvalid <= 1'b0;
                
                if (s_axis_tvalid) begin
                    // First beat of frame - check destination MAC
                    // Assuming Ethernet header layout: dst_mac in upper bytes
                    dst_mac <= s_axis_tdata[47:0];
                    
                    // Capture current timestamp
                    frame_timestamp <= timestamp_counter;
                    
                    // Check if MAC matches configured value
                    if (s_axis_tdata[47:0] == cfg_dst_mac) begin
                        // Accept frame
                        frame_accepted <= 1'b1;
                        accept_count   <= accept_count + 32'd1;
                        
                        // Forward first beat
                        m_axis_tdata  <= s_axis_tdata;
                        m_axis_tkeep  <= s_axis_tkeep;
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast  <= s_axis_tlast;
                        m_axis_tuser  <= frame_timestamp;
                        
                        state <= s_axis_tlast ? ST_IDLE : ST_FORWARD;
                        
                    end else begin
                        // Drop frame
                        frame_accepted <= 1'b0;
                        drop_count     <= drop_count + 32'd1;
                        state          <= ST_DROP;
                    end
                end
            end
            
            ST_FORWARD: begin
                // Forward frame data
                if (s_axis_tvalid && m_axis_tready) begin
                    m_axis_tdata  <= s_axis_tdata;
                    m_axis_tkeep  <= s_axis_tkeep;
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= s_axis_tlast;
                    m_axis_tuser  <= frame_timestamp;  // Propagate same timestamp
                    
                    if (s_axis_tlast)
                        state <= ST_IDLE;
                        
                end else if (!m_axis_tready) begin
                    // Downstream stall - hold data
                    m_axis_tvalid <= 1'b1;
                end
            end
            
            ST_DROP: begin
                // Silently drop until end of frame
                m_axis_tvalid <= 1'b0;
                
                if (s_axis_tvalid && s_axis_tlast)
                    state <= ST_IDLE;
            end
            
            default: state <= ST_IDLE;
        endcase
    end
end

// Back-pressure handling
// Ready when: idle, forwarding and downstream ready, or dropping
assign s_axis_tready = (state == ST_IDLE) || 
                       (state == ST_FORWARD && m_axis_tready) ||
                       (state == ST_DROP);

endmodule
