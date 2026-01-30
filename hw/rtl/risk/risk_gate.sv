//-----------------------------------------------------------------------------
// File: risk_gate.sv
// Description: Deterministic single-cycle risk gate implementing:
//              - Price band check (basis points from reference)
//              - Token bucket rate limiting
//              - Position/notional limits
//              - Global kill switch
//              - Stale data interlock
//              - Sequence gap interlock
//
// All checks execute in parallel for single-cycle decision.
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module risk_gate (
    input  logic                    clk,
    input  logic                    rst_n,
    
    //-------------------------------------------------------------------------
    // Book Event Input (from book_tob)
    //-------------------------------------------------------------------------
    input  book_event_t             event_in,
    input  logic                    event_valid,
    output logic                    event_ready,
    
    //-------------------------------------------------------------------------
    // Risk Decision Output
    //-------------------------------------------------------------------------
    output risk_output_t            decision_out,
    output logic                    decision_valid,
    input  logic                    decision_ready,
    
    //-------------------------------------------------------------------------
    // Timestamp Input
    //-------------------------------------------------------------------------
    input  logic [63:0]             timestamp_cnt,
    
    //-------------------------------------------------------------------------
    // Configuration (from CSR, synchronized)
    //-------------------------------------------------------------------------
    input  logic                    cfg_enable,
    input  logic [15:0]             cfg_price_band_bps,    // Max deviation in basis points
    input  logic [15:0]             cfg_token_rate,        // Tokens per millisecond
    input  logic [15:0]             cfg_token_max,         // Max bucket size
    input  logic signed [31:0]      cfg_position_limit,    // Max notional per symbol
    input  logic [31:0]             cfg_stale_usec,        // Max staleness (microseconds)
    input  logic [15:0]             cfg_seq_gap_thr,       // Seq gap threshold
    input  logic                    cfg_kill,              // Global kill switch
    input  logic                    cfg_gpio_enable,       // Enable GPIO output
    
    //-------------------------------------------------------------------------
    // Reference Price Interface (for price band check)
    //-------------------------------------------------------------------------
    output logic [SYMBOL_IDX_WIDTH-1:0] ref_price_addr,
    output logic                    ref_price_rd,
    input  logic [31:0]             ref_price_data,
    input  logic                    ref_price_valid,
    
    //-------------------------------------------------------------------------
    // GPIO Output
    //-------------------------------------------------------------------------
    output logic                    gpio_pulse,
    
    //-------------------------------------------------------------------------
    // Audit FIFO Interface
    //-------------------------------------------------------------------------
    output logic [63:0]             audit_data,
    output logic                    audit_valid,
    input  logic                    audit_ready,
    
    //-------------------------------------------------------------------------
    // Statistics
    //-------------------------------------------------------------------------
    output logic [31:0]             stat_accepts,
    output logic [31:0]             stat_rejects,
    output logic [31:0]             stat_price_band_fails,
    output logic [31:0]             stat_token_fails,
    output logic [31:0]             stat_position_fails,
    output logic [31:0]             stat_kill_blocks,
    output logic [31:0]             stat_stale_blocks
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    
    // Token bucket replenish interval (cycles at 300 MHz for 1 ms)
    localparam int unsigned TOKEN_REPLENISH_CYCLES = 300000;
    
    // GPIO pulse width (cycles at 300 MHz for ~30 ns)
    localparam int unsigned GPIO_PULSE_WIDTH = 10;
    
    //=========================================================================
    // Signal Declarations
    //=========================================================================
    
    // Pipeline stages
    typedef enum logic [1:0] {
        RISK_IDLE,
        RISK_CHECK,
        RISK_DECIDE
    } risk_state_e;
    
    risk_state_e state;
    
    // Registered event
    book_event_t event_reg;
    logic [63:0] decision_ts;
    
    // Risk check results (all computed in parallel)
    logic        check_price_band_ok;
    logic        check_token_ok;
    logic        check_position_ok;
    logic        check_not_stale;
    logic        check_not_killed;
    logic        check_no_seq_gap;
    
    // Overall decision
    logic        accept;
    risk_reason_e reject_reason;
    
    // Token bucket state
    logic [31:0] token_bucket;
    logic [31:0] token_replenish_cnt;
    
    // Price band calculation
    logic [31:0] ref_price_reg;
    logic [63:0] price_diff_abs;
    logic [63:0] band_threshold;
    
    // GPIO pulse generator
    logic [3:0]  gpio_pulse_cnt;
    logic        gpio_trigger;
    
    // Output registers
    risk_output_t decision_reg;
    logic         decision_pending;
    
    //=========================================================================
    // Token Bucket Rate Limiter
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            token_bucket       <= '0;
            token_replenish_cnt <= '0;
        end else begin
            // Replenish tokens periodically
            if (token_replenish_cnt >= TOKEN_REPLENISH_CYCLES - 1) begin
                token_replenish_cnt <= '0;
                if (token_bucket < cfg_token_max) begin
                    token_bucket <= (token_bucket + cfg_token_rate > cfg_token_max) ? 
                                   cfg_token_max : token_bucket + cfg_token_rate;
                end
            end else begin
                token_replenish_cnt <= token_replenish_cnt + 1;
            end
            
            // Consume token on accept
            if (decision_valid && decision_ready && decision_reg.accept) begin
                if (token_bucket > 0) begin
                    token_bucket <= token_bucket - 1;
                end
            end
        end
    end
    
    assign check_token_ok = (token_bucket > 0);
    
    //=========================================================================
    // Price Band Check
    //=========================================================================
    
    // Request reference price when event arrives
    assign ref_price_addr = event_reg.symbol_idx;
    assign ref_price_rd   = (state == RISK_CHECK);
    
    // Capture reference price
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_price_reg <= '0;
        end else if (ref_price_valid) begin
            ref_price_reg <= ref_price_data;
        end
    end
    
    // Calculate price deviation in basis points
    // |price - ref_price| * 10000 / ref_price <= cfg_price_band_bps
    // Rearranged: |price - ref_price| * 10000 <= cfg_price_band_bps * ref_price
    
    always_comb begin
        logic [31:0] current_price;
        logic [31:0] ref_px;
        
        // Use mid-price or last trade price as current
        current_price = (event_reg.tob.bid_px + event_reg.tob.ask_px) >> 1;
        ref_px = ref_price_reg;
        
        // Calculate absolute difference
        if (current_price >= ref_px) begin
            price_diff_abs = current_price - ref_px;
        end else begin
            price_diff_abs = ref_px - current_price;
        end
        
        // Threshold = ref_price * band_bps / 10000
        // For efficiency: compare price_diff * 10000 vs ref_price * band_bps
        band_threshold = ({32'b0, ref_px} * {16'b0, cfg_price_band_bps});
    end
    
    assign check_price_band_ok = ((price_diff_abs * 64'd10000) <= band_threshold) ||
                                  (ref_price_reg == 0) ||  // No ref price yet
                                  (cfg_price_band_bps == 0);  // Check disabled
    
    //=========================================================================
    // Position Limit Check
    //=========================================================================
    
    // Simplified: just check that event quantity is within limits
    // Real implementation would track per-symbol position
    assign check_position_ok = (event_reg.tob.bid_qty <= cfg_position_limit[30:0]) &&
                               (event_reg.tob.ask_qty <= cfg_position_limit[30:0]);
    
    //=========================================================================
    // Staleness Check
    //=========================================================================
    
    logic [63:0] data_age_cycles;
    logic [63:0] stale_threshold_cycles;
    
    // Calculate age of data
    assign data_age_cycles = timestamp_cnt - event_reg.book_ts;
    
    // Convert microseconds to cycles (300 cycles per microsecond at 300 MHz)
    assign stale_threshold_cycles = {32'b0, cfg_stale_usec} * 64'd300;
    
    assign check_not_stale = (data_age_cycles <= stale_threshold_cycles) || !event_reg.stale;
    
    //=========================================================================
    // Kill Switch and Sequence Gap Checks
    //=========================================================================
    
    assign check_not_killed = !cfg_kill;
    assign check_no_seq_gap = !event_reg.stale;  // Stale flag indicates seq gap upstream
    
    //=========================================================================
    // State Machine
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= RISK_IDLE;
            event_reg        <= '0;
            decision_ts      <= '0;
            decision_reg     <= '0;
            decision_pending <= 1'b0;
        end else begin
            case (state)
                RISK_IDLE: begin
                    decision_pending <= 1'b0;
                    
                    if (event_valid && event_ready && cfg_enable) begin
                        event_reg   <= event_in;
                        decision_ts <= timestamp_cnt;
                        state       <= RISK_CHECK;
                    end
                end
                
                RISK_CHECK: begin
                    // Wait one cycle for reference price lookup
                    // All checks are combinational from registered inputs
                    state <= RISK_DECIDE;
                end
                
                RISK_DECIDE: begin
                    // Make final decision
                    if (check_not_killed && check_not_stale && check_no_seq_gap &&
                        check_price_band_ok && check_token_ok && check_position_ok) begin
                        accept        <= 1'b1;
                        reject_reason <= RISK_ACCEPT;
                    end else begin
                        accept <= 1'b0;
                        
                        // Priority encode rejection reason
                        if (!check_not_killed) begin
                            reject_reason <= RISK_KILL_SWITCH;
                        end else if (!check_not_stale) begin
                            reject_reason <= RISK_STALE_DATA;
                        end else if (!check_no_seq_gap) begin
                            reject_reason <= RISK_SEQ_GAP;
                        end else if (!check_price_band_ok) begin
                            reject_reason <= RISK_PRICE_BAND;
                        end else if (!check_token_ok) begin
                            reject_reason <= RISK_TOKEN_BUCKET;
                        end else begin
                            reject_reason <= RISK_POSITION_LIMIT;
                        end
                    end
                    
                    // Build output
                    decision_reg.accept      <= accept;
                    decision_reg.reason      <= reject_reason;
                    decision_reg.decision_ts <= decision_ts;
                    decision_reg.book_event  <= event_reg;
                    
                    decision_pending <= 1'b1;
                    
                    if (decision_ready || !decision_pending) begin
                        state <= RISK_IDLE;
                    end
                end
            endcase
        end
    end
    
    //=========================================================================
    // GPIO Pulse Generator
    //=========================================================================
    
    assign gpio_trigger = decision_valid && decision_ready && decision_reg.accept && cfg_gpio_enable;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gpio_pulse_cnt <= '0;
            gpio_pulse     <= 1'b0;
        end else begin
            if (gpio_trigger) begin
                gpio_pulse_cnt <= GPIO_PULSE_WIDTH;
                gpio_pulse     <= 1'b1;
            end else if (gpio_pulse_cnt > 0) begin
                gpio_pulse_cnt <= gpio_pulse_cnt - 1;
                if (gpio_pulse_cnt == 1) begin
                    gpio_pulse <= 1'b0;
                end
            end
        end
    end
    
    //=========================================================================
    // Audit FIFO Output
    //=========================================================================
    
    // Compact audit record: {timestamp[47:0], symbol_idx[9:0], reason[3:0], accept[0], reserved[1:0]}
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            audit_data  <= '0;
            audit_valid <= 1'b0;
        end else begin
            if (decision_valid && decision_ready) begin
                audit_data <= {decision_ts[47:0], 
                              event_reg.symbol_idx,
                              decision_reg.reason,
                              decision_reg.accept,
                              1'b0};
                audit_valid <= 1'b1;
            end else if (audit_ready) begin
                audit_valid <= 1'b0;
            end
        end
    end
    
    //=========================================================================
    // Output Assignments
    //=========================================================================
    
    assign decision_out   = decision_reg;
    assign decision_valid = decision_pending && (state == RISK_DECIDE || state == RISK_IDLE);
    assign event_ready    = (state == RISK_IDLE) && cfg_enable;
    
    //=========================================================================
    // Statistics
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stat_accepts          <= '0;
            stat_rejects          <= '0;
            stat_price_band_fails <= '0;
            stat_token_fails      <= '0;
            stat_position_fails   <= '0;
            stat_kill_blocks      <= '0;
            stat_stale_blocks     <= '0;
        end else if (decision_valid && decision_ready) begin
            if (decision_reg.accept) begin
                stat_accepts <= stat_accepts + 1'b1;
            end else begin
                stat_rejects <= stat_rejects + 1'b1;
                
                case (decision_reg.reason)
                    RISK_PRICE_BAND:    stat_price_band_fails <= stat_price_band_fails + 1'b1;
                    RISK_TOKEN_BUCKET:  stat_token_fails      <= stat_token_fails + 1'b1;
                    RISK_POSITION_LIMIT: stat_position_fails  <= stat_position_fails + 1'b1;
                    RISK_KILL_SWITCH:   stat_kill_blocks      <= stat_kill_blocks + 1'b1;
                    RISK_STALE_DATA,
                    RISK_SEQ_GAP:       stat_stale_blocks     <= stat_stale_blocks + 1'b1;
                    default: ;
                endcase
            end
        end
    end

endmodule : risk_gate
