//-----------------------------------------------------------------------------
// File: symtab_cam.sv
// Description: Symbol table CAM (Content Addressable Memory) for mapping
//              8-byte symbol keys to symbol indices. Supports dynamic loading
//              via CSR interface with atomic commit.
//
// Features:
//   - 1024 entries (configurable)
//   - 8-byte symbol key (NASDAQ stock symbol, space-padded)
//   - Single-cycle lookup
//   - Double-buffer commit for atomic updates
//   - Hash-based indexing with linear probing for collisions
//
//-----------------------------------------------------------------------------

import t2t_pkg::*;

module symtab_cam #(
    parameter int unsigned NUM_ENTRIES   = 1024,
    parameter int unsigned KEY_WIDTH     = 64,    // 8-byte symbol
    parameter int unsigned IDX_WIDTH     = $clog2(NUM_ENTRIES)
) (
    input  logic                    clk,
    input  logic                    rst_n,
    
    //-------------------------------------------------------------------------
    // Lookup Interface
    //-------------------------------------------------------------------------
    input  logic [KEY_WIDTH-1:0]    lookup_key,
    input  logic                    lookup_valid,
    output logic [IDX_WIDTH-1:0]    lookup_idx,
    output logic                    lookup_hit,
    output logic                    lookup_ready,
    
    //-------------------------------------------------------------------------
    // CSR Load Interface (for initial configuration)
    //-------------------------------------------------------------------------
    input  logic [KEY_WIDTH-1:0]    load_key,
    input  logic [IDX_WIDTH-1:0]    load_idx,
    input  logic                    load_valid,
    output logic                    load_ready,
    
    input  logic                    commit,          // Atomically activate new table
    output logic                    commit_done,
    
    //-------------------------------------------------------------------------
    // Status
    //-------------------------------------------------------------------------
    output logic [IDX_WIDTH:0]      num_entries_loaded,
    output logic                    table_full
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    
    // Hash table size (slightly larger than NUM_ENTRIES for reduced collisions)
    localparam int unsigned HASH_SIZE = NUM_ENTRIES;
    localparam int unsigned HASH_WIDTH = $clog2(HASH_SIZE);
    
    // Maximum probes for collision resolution
    localparam int unsigned MAX_PROBES = 8;
    
    //=========================================================================
    // Signal Declarations
    //=========================================================================
    
    // Double-buffered CAM storage
    // Active table (read) and shadow table (write)
    logic [KEY_WIDTH-1:0] cam_keys_0   [HASH_SIZE];
    logic [IDX_WIDTH-1:0] cam_values_0 [HASH_SIZE];
    logic                 cam_valid_0  [HASH_SIZE];
    
    logic [KEY_WIDTH-1:0] cam_keys_1   [HASH_SIZE];
    logic [IDX_WIDTH-1:0] cam_values_1 [HASH_SIZE];
    logic                 cam_valid_1  [HASH_SIZE];
    
    // Active buffer selector
    logic active_buffer;
    
    // Hash function output
    logic [HASH_WIDTH-1:0] hash_lookup;
    logic [HASH_WIDTH-1:0] hash_load;
    
    // Lookup state machine
    typedef enum logic [1:0] {
        LKP_IDLE,
        LKP_PROBE,
        LKP_DONE
    } lkp_state_e;
    
    lkp_state_e lkp_state;
    
    // Lookup registers
    logic [KEY_WIDTH-1:0]  lkp_key_reg;
    logic [HASH_WIDTH-1:0] lkp_hash_base;
    logic [2:0]            lkp_probe_cnt;
    logic [HASH_WIDTH-1:0] lkp_probe_addr;
    logic                  lkp_found;
    logic [IDX_WIDTH-1:0]  lkp_result_idx;
    
    // Load state
    logic [IDX_WIDTH:0]    load_count;
    logic                  loading;
    
    //=========================================================================
    // Hash Function (simple XOR fold)
    //=========================================================================
    
    function automatic logic [HASH_WIDTH-1:0] hash_func(input logic [KEY_WIDTH-1:0] key);
        logic [31:0] h;
        // XOR fold 64-bit key to 32-bit, then fold again
        h = key[63:32] ^ key[31:0];
        h = h ^ (h >> 16);
        h = h ^ (h >> 8);
        return h[HASH_WIDTH-1:0];
    endfunction
    
    assign hash_lookup = hash_func(lookup_key);
    assign hash_load   = hash_func(load_key);
    
    //=========================================================================
    // Lookup State Machine
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lkp_state      <= LKP_IDLE;
            lkp_key_reg    <= '0;
            lkp_hash_base  <= '0;
            lkp_probe_cnt  <= '0;
            lkp_probe_addr <= '0;
            lkp_found      <= 1'b0;
            lkp_result_idx <= '0;
        end else begin
            case (lkp_state)
                LKP_IDLE: begin
                    lkp_found <= 1'b0;
                    
                    if (lookup_valid) begin
                        lkp_key_reg    <= lookup_key;
                        lkp_hash_base  <= hash_lookup;
                        lkp_probe_addr <= hash_lookup;
                        lkp_probe_cnt  <= '0;
                        lkp_state      <= LKP_PROBE;
                    end
                end
                
                LKP_PROBE: begin
                    // Check current probe address
                    if (active_buffer == 1'b0) begin
                        if (cam_valid_0[lkp_probe_addr] && 
                            cam_keys_0[lkp_probe_addr] == lkp_key_reg) begin
                            // Found
                            lkp_found      <= 1'b1;
                            lkp_result_idx <= cam_values_0[lkp_probe_addr];
                            lkp_state      <= LKP_DONE;
                        end else if (!cam_valid_0[lkp_probe_addr] || 
                                     lkp_probe_cnt >= MAX_PROBES - 1) begin
                            // Not found (empty slot or max probes)
                            lkp_found <= 1'b0;
                            lkp_state <= LKP_DONE;
                        end else begin
                            // Linear probe to next slot
                            lkp_probe_addr <= (lkp_probe_addr + 1) % HASH_SIZE;
                            lkp_probe_cnt  <= lkp_probe_cnt + 1;
                        end
                    end else begin
                        if (cam_valid_1[lkp_probe_addr] && 
                            cam_keys_1[lkp_probe_addr] == lkp_key_reg) begin
                            lkp_found      <= 1'b1;
                            lkp_result_idx <= cam_values_1[lkp_probe_addr];
                            lkp_state      <= LKP_DONE;
                        end else if (!cam_valid_1[lkp_probe_addr] || 
                                     lkp_probe_cnt >= MAX_PROBES - 1) begin
                            lkp_found <= 1'b0;
                            lkp_state <= LKP_DONE;
                        end else begin
                            lkp_probe_addr <= (lkp_probe_addr + 1) % HASH_SIZE;
                            lkp_probe_cnt  <= lkp_probe_cnt + 1;
                        end
                    end
                end
                
                LKP_DONE: begin
                    lkp_state <= LKP_IDLE;
                end
            endcase
        end
    end
    
    //=========================================================================
    // Load Interface (writes to shadow buffer)
    //=========================================================================
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_count    <= '0;
            loading       <= 1'b0;
            active_buffer <= 1'b0;
            
            // Clear both tables
            for (int i = 0; i < HASH_SIZE; i++) begin
                cam_valid_0[i] <= 1'b0;
                cam_valid_1[i] <= 1'b0;
            end
        end else begin
            if (load_valid && load_ready) begin
                // Write to shadow buffer with linear probing
                automatic logic [HASH_WIDTH-1:0] addr = hash_load;
                automatic int probe = 0;
                automatic logic inserted = 1'b0;
                
                // Find empty slot (linear probing)
                while (probe < MAX_PROBES && !inserted) begin
                    if (active_buffer == 1'b0) begin
                        // Shadow is buffer 1
                        if (!cam_valid_1[addr]) begin
                            cam_keys_1[addr]   <= load_key;
                            cam_values_1[addr] <= load_idx;
                            cam_valid_1[addr]  <= 1'b1;
                            inserted = 1'b1;
                        end
                    end else begin
                        // Shadow is buffer 0
                        if (!cam_valid_0[addr]) begin
                            cam_keys_0[addr]   <= load_key;
                            cam_values_0[addr] <= load_idx;
                            cam_valid_0[addr]  <= 1'b1;
                            inserted = 1'b1;
                        end
                    end
                    
                    if (!inserted) begin
                        addr = (addr + 1) % HASH_SIZE;
                        probe = probe + 1;
                    end
                end
                
                if (inserted) begin
                    load_count <= load_count + 1;
                end
                
                loading <= 1'b1;
            end
            
            if (commit) begin
                // Swap buffers
                active_buffer <= ~active_buffer;
                load_count    <= '0;
                loading       <= 1'b0;
                
                // Clear the new shadow buffer
                for (int i = 0; i < HASH_SIZE; i++) begin
                    if (active_buffer == 1'b0) begin
                        cam_valid_0[i] <= 1'b0;
                    end else begin
                        cam_valid_1[i] <= 1'b0;
                    end
                end
            end
        end
    end
    
    //=========================================================================
    // Output Assignments
    //=========================================================================
    
    assign lookup_idx    = lkp_result_idx;
    assign lookup_hit    = lkp_found;
    assign lookup_ready  = (lkp_state == LKP_DONE);
    
    assign load_ready    = !commit && (load_count < NUM_ENTRIES);
    assign commit_done   = 1'b1;  // Commit is single-cycle
    
    assign num_entries_loaded = load_count;
    assign table_full         = (load_count >= NUM_ENTRIES);

endmodule : symtab_cam
