//-----------------------------------------------------------------------------
// File: t2t_pkg.sv
// Description: Main package containing type definitions, parameters, and 
//              constants for the T2T-C10GX tick-to-trade pipeline.
//
//-----------------------------------------------------------------------------

package t2t_pkg;

    //=========================================================================
    // Global Parameters
    //=========================================================================
    
    // Clock frequencies (for reference - actual values from PLLs)
    parameter int unsigned MAC_CLK_FREQ_MHZ  = 156;    // 156.25 MHz
    parameter int unsigned CORE_CLK_FREQ_MHZ = 300;    // 300 MHz
    parameter int unsigned PCIE_CLK_FREQ_MHZ = 125;    // 125 MHz
    parameter int unsigned CSR_CLK_FREQ_MHZ  = 100;    // 100 MHz
    
    // Data widths
    parameter int unsigned AXI_DATA_WIDTH    = 64;     // AXI-Stream data width
    parameter int unsigned AXI_KEEP_WIDTH    = AXI_DATA_WIDTH / 8;
    parameter int unsigned TIMESTAMP_WIDTH   = 64;     // 64-bit timestamps
    
    // Symbol parameters
    parameter int unsigned MAX_SYMBOLS       = 1024;
    parameter int unsigned SYMBOL_IDX_WIDTH  = $clog2(MAX_SYMBOLS);  // 10 bits
    parameter int unsigned SYMBOL_KEY_WIDTH  = 64;     // 8-byte symbol key
    
    // Book parameters
    parameter int unsigned BOOK_BANKS        = 4;
    parameter int unsigned PRICE_WIDTH       = 32;
    parameter int unsigned QTY_WIDTH         = 32;
    
    // DMA parameters
    parameter int unsigned DMA_RECORD_BYTES  = 64;
    parameter int unsigned DMA_RING_DEPTH    = 65536;
    parameter int unsigned DMA_IDX_WIDTH     = $clog2(DMA_RING_DEPTH);  // 16 bits
    
    // ITCH parameters
    parameter int unsigned ITCH_SEQ_WIDTH    = 32;
    parameter int unsigned ITCH_ORDERID_WIDTH = 64;
    
    //=========================================================================
    // Enumerations
    //=========================================================================
    
    // ITCH 5.0 message types
    typedef enum logic [7:0] {
        ITCH_SYSTEM_EVENT       = 8'h53,  // 'S'
        ITCH_STOCK_DIRECTORY    = 8'h52,  // 'R'
        ITCH_STOCK_TRADING_ACTION = 8'h48, // 'H'
        ITCH_REG_SHO            = 8'h59,  // 'Y'
        ITCH_MARKET_PARTICIPANT = 8'h4C,  // 'L'
        ITCH_MWCB_DECLINE       = 8'h56,  // 'V'
        ITCH_MWCB_STATUS        = 8'h57,  // 'W'
        ITCH_IPO_QUOTE          = 8'h4B,  // 'K'
        ITCH_ADD_ORDER          = 8'h41,  // 'A'
        ITCH_ADD_ORDER_MPID     = 8'h46,  // 'F'
        ITCH_ORDER_EXECUTED     = 8'h45,  // 'E'
        ITCH_ORDER_EXECUTED_PX  = 8'h43,  // 'C'
        ITCH_ORDER_CANCEL       = 8'h58,  // 'X'
        ITCH_ORDER_DELETE       = 8'h44,  // 'D'
        ITCH_ORDER_REPLACE      = 8'h55,  // 'U'
        ITCH_TRADE              = 8'h50,  // 'P'
        ITCH_CROSS_TRADE        = 8'h51,  // 'Q'
        ITCH_BROKEN_TRADE       = 8'h42,  // 'B'
        ITCH_NOII               = 8'h49,  // 'I'
        ITCH_RPII               = 8'h4E,  // 'N'
        ITCH_UNKNOWN            = 8'hFF
    } itch_msg_type_e;
    
    // Side indicator
    typedef enum logic {
        SIDE_BID = 1'b0,
        SIDE_ASK = 1'b1
    } side_e;
    
    // Risk gate rejection reasons
    typedef enum logic [3:0] {
        RISK_ACCEPT          = 4'h0,
        RISK_PRICE_BAND      = 4'h1,
        RISK_TOKEN_BUCKET    = 4'h2,
        RISK_POSITION_LIMIT  = 4'h3,
        RISK_KILL_SWITCH     = 4'h4,
        RISK_STALE_DATA      = 4'h5,
        RISK_SEQ_GAP         = 4'h6,
        RISK_HALT            = 4'h7,
        RISK_UNKNOWN_SYMBOL  = 4'h8,
        RISK_RESERVED        = 4'hF
    } risk_reason_e;
    
    // Parser error flags
    typedef enum logic [3:0] {
        PARSE_OK             = 4'h0,
        PARSE_CRC_ERROR      = 4'h1,
        PARSE_LENGTH_ERROR   = 4'h2,
        PARSE_IP_CHECKSUM    = 4'h3,
        PARSE_UNSUPPORTED    = 4'h4,
        PARSE_TRUNCATED      = 4'h5
    } parse_error_e;
    
    //=========================================================================
    // Structures
    //=========================================================================
    
    // AXI-Stream TUSER sideband at MAC egress
    typedef struct packed {
        logic [TIMESTAMP_WIDTH-1:0] ingress_ts;   // Ingress timestamp
        logic                       crc_ok;        // CRC check passed
        logic                       is_multicast;  // Multicast destination
        logic [1:0]                 vlan_count;    // Number of VLAN tags (0-2)
        logic [3:0]                 error_flags;   // Error indicators
    } mac_tuser_t;
    
    // Parsed packet metadata (after L2/L3/L4 parsing)
    typedef struct packed {
        logic [TIMESTAMP_WIDTH-1:0] ingress_ts;
        logic [31:0]                src_ip;
        logic [31:0]                dst_ip;
        logic [15:0]                src_port;
        logic [15:0]                dst_port;
        logic [15:0]                udp_len;
        logic [15:0]                payload_offset;  // Byte offset to UDP payload
        logic [3:0]                 parse_error;
        logic                       is_valid;
    } parsed_pkt_t;
    
    // ITCH message (decoded)
    typedef struct packed {
        logic [TIMESTAMP_WIDTH-1:0] ingress_ts;
        logic [TIMESTAMP_WIDTH-1:0] decode_ts;
        logic [ITCH_SEQ_WIDTH-1:0]  seq_num;
        itch_msg_type_e             msg_type;
        logic [SYMBOL_KEY_WIDTH-1:0] symbol_key;
        logic [SYMBOL_IDX_WIDTH-1:0] symbol_idx;
        logic                       symbol_valid;
        side_e                      side;
        logic [PRICE_WIDTH-1:0]     price;
        logic [QTY_WIDTH-1:0]       qty;
        logic [ITCH_ORDERID_WIDTH-1:0] order_id;
        logic                       is_book_update;  // Affects order book
        logic                       stale;           // Stale data flag
        logic [3:0]                 error_flags;
    } itch_msg_t;
    
    // Top-of-book entry
    typedef struct packed {
        logic [PRICE_WIDTH-1:0]     bid_px;
        logic [QTY_WIDTH-1:0]       bid_qty;
        logic [PRICE_WIDTH-1:0]     ask_px;
        logic [QTY_WIDTH-1:0]       ask_qty;
        logic [TIMESTAMP_WIDTH-1:0] last_update_ts;
        logic                       valid;
    } tob_entry_t;
    
    // Book update event (output from book builder)
    typedef struct packed {
        logic [TIMESTAMP_WIDTH-1:0] ingress_ts;
        logic [TIMESTAMP_WIDTH-1:0] book_ts;
        logic [SYMBOL_IDX_WIDTH-1:0] symbol_idx;
        tob_entry_t                 tob;
        logic [PRICE_WIDTH-1:0]     last_trade_px;
        logic [QTY_WIDTH-1:0]       last_trade_qty;
        logic                       tob_changed;
        logic                       trade_occurred;
        logic                       stale;
        itch_msg_type_e             trigger_msg_type;
    } book_event_t;
    
    // Risk gate input
    typedef struct packed {
        book_event_t                book_event;
        logic [31:0]                ref_price;       // Reference price for band check
        logic signed [31:0]         position;        // Current position (signed)
        logic [31:0]                notional;        // Notional value
    } risk_input_t;
    
    // Risk gate output
    typedef struct packed {
        logic                       accept;
        risk_reason_e               reason;
        logic [TIMESTAMP_WIDTH-1:0] decision_ts;
        book_event_t                book_event;      // Pass-through
    } risk_output_t;
    
    // DMA record (64 bytes)
    typedef struct packed {
        logic [63:0]                reserved_hi;     // Bytes 56-63
        logic [15:0]                pad;
        logic [15:0]                payload_crc16;
        logic [31:0]                feature2;        // Last trade price
        logic [31:0]                feature1;        // Order imbalance
        logic [31:0]                feature0;        // Bid-ask spread
        logic [31:0]                ref_px;
        logic [31:0]                price;
        logic [31:0]                qty;
        logic [7:0]                 flags;
        logic [7:0]                 side;
        logic [15:0]                sym_idx;
        logic [63:0]                ts_dec;
        logic [63:0]                ts_ing;
        logic [31:0]                reserved_lo;
        logic [31:0]                seq;
    } dma_record_t;
    
    // CSR register addresses (Avalon-MM byte addresses)
    typedef enum logic [11:0] {
        CSR_BUILD_ID        = 12'h000,
        CSR_CTRL            = 12'h004,
        CSR_PRICE_BAND_BPS  = 12'h008,
        CSR_TOKEN_RATE      = 12'h00C,
        CSR_POSITION_LIMIT  = 12'h010,
        CSR_STALE_USEC      = 12'h014,
        CSR_SEQ_GAP_THR     = 12'h018,
        CSR_KILL            = 12'h01C,
        CSR_SYMTAB_DATA     = 12'h020,
        CSR_SYMTAB_COMMIT   = 12'h040,
        CSR_LAT_HIST_BASE   = 12'h100,
        CSR_DROPS           = 12'h180,
        CSR_CRC_BAD         = 12'h184,
        CSR_SEQ_GAPS        = 12'h188,
        CSR_ACCEPTS         = 12'h18C,
        CSR_BLOCKS          = 12'h190,
        CSR_EVENT_LOG       = 12'h200,
        CSR_RING_BASE_LO    = 12'h300,
        CSR_RING_BASE_HI    = 12'h304,
        CSR_RING_LEN        = 12'h308,
        CSR_PROD_IDX        = 12'h320,
        CSR_CONS_IDX_SHADOW = 12'h324,
        CSR_MSIX_CFG        = 12'h328
    } csr_addr_e;
    
    //=========================================================================
    // Functions
    //=========================================================================
    
    // Calculate CRC-16 (CCITT) for DMA record integrity
    function automatic logic [15:0] crc16_ccitt(
        input logic [7:0] data [],
        input int unsigned len
    );
        logic [15:0] crc;
        logic [7:0] b;
        int i, j;
        
        crc = 16'hFFFF;
        for (i = 0; i < len; i++) begin
            b = data[i];
            crc = crc ^ (b << 8);
            for (j = 0; j < 8; j++) begin
                if (crc[15])
                    crc = (crc << 1) ^ 16'h1021;
                else
                    crc = crc << 1;
            end
        end
        return crc;
    endfunction
    
    // Check if ITCH message type affects order book
    function automatic logic is_book_affecting(itch_msg_type_e msg_type);
        case (msg_type)
            ITCH_ADD_ORDER,
            ITCH_ADD_ORDER_MPID,
            ITCH_ORDER_EXECUTED,
            ITCH_ORDER_EXECUTED_PX,
            ITCH_ORDER_CANCEL,
            ITCH_ORDER_DELETE,
            ITCH_ORDER_REPLACE,
            ITCH_TRADE:
                return 1'b1;
            default:
                return 1'b0;
        endcase
    endfunction
    
    // Get ITCH message length (bytes) from message type
    function automatic int unsigned itch_msg_length(itch_msg_type_e msg_type);
        case (msg_type)
            ITCH_SYSTEM_EVENT:       return 12;
            ITCH_STOCK_DIRECTORY:    return 39;
            ITCH_ADD_ORDER:          return 36;
            ITCH_ADD_ORDER_MPID:     return 40;
            ITCH_ORDER_EXECUTED:     return 31;
            ITCH_ORDER_EXECUTED_PX:  return 36;
            ITCH_ORDER_CANCEL:       return 23;
            ITCH_ORDER_DELETE:       return 19;
            ITCH_ORDER_REPLACE:      return 35;
            ITCH_TRADE:              return 44;
            ITCH_CROSS_TRADE:        return 40;
            ITCH_NOII:               return 50;
            default:                 return 0;  // Unknown
        endcase
    endfunction

endpackage : t2t_pkg
