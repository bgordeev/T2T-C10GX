// ============================================================================
// Module: action_gpio.sv
// Description: GPIO action output - generates hardware pulse on trading signal
//              Drives FPGA output pin high for configurable duration
// ============================================================================

module action_gpio #(
    parameter PULSE_WIDTH_CYCLES = 10    // Default: 10 cycles = 35 ns @ 285 MHz
)(
    input  logic        clk,
    input  logic        rst_n,
    
    // Signal input (from risk gate)
    input  logic        signal_valid,    // Pulse high for 1 cycle to trigger
    input  logic [15:0] signal_data,     // Optional: signal metadata
    
    // GPIO output
    output logic        gpio_pulse,      // Physical output pin
    
    // CSR configuration
    input  logic [7:0]  cfg_pulse_width, // Configurable pulse width (0 = use default)
    input  logic        cfg_enable,      // Enable GPIO output
    
    // Statistics
    output logic [31:0] pulse_count
);

// ============================================================================
// Pulse generator state machine
// ============================================================================
typedef enum logic [1:0] {
    ST_IDLE,
    ST_PULSE,
    ST_COOLDOWN
} state_t;

state_t state;

logic [7:0] pulse_counter;
logic [7:0] active_pulse_width;

// Use configured width if non-zero, otherwise use parameter default
assign active_pulse_width = (cfg_pulse_width != 8'h0) ? 
                            cfg_pulse_width : 
                            PULSE_WIDTH_CYCLES[7:0];

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state         <= ST_IDLE;
        gpio_pulse    <= 1'b0;
        pulse_counter <= 8'h0;
        pulse_count   <= 32'h0;
        
    end else begin
        case (state)
            ST_IDLE: begin
                gpio_pulse <= 1'b0;
                
                if (signal_valid && cfg_enable) begin
                    // Start pulse
                    gpio_pulse    <= 1'b1;
                    pulse_counter <= 8'h1;
                    pulse_count   <= pulse_count + 32'd1;
                    state         <= ST_PULSE;
                end
            end
            
            ST_PULSE: begin
                // Hold pulse high for configured duration
                gpio_pulse <= 1'b1;
                pulse_counter <= pulse_counter + 8'd1;
                
                if (pulse_counter >= active_pulse_width) begin
                    gpio_pulse <= 1'b0;
                    state      <= ST_IDLE;
                end
            end
            
            default: state <= ST_IDLE;
        endcase
    end
end

// ============================================================================
// Synthesis attributes for timing
// Tell synthesis tool this is a critical output path
// ============================================================================
// synthesis translate_off
initial begin
    $display("GPIO Action Module: pulse_width=%0d cycles", PULSE_WIDTH_CYCLES);
end
// synthesis translate_on

endmodule
