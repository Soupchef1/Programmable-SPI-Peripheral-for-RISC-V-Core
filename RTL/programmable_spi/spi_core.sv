/**********************************************
* Module Name        : spi_core
* Authors            : Ryan Karami, Saahas Swaroop, Francis Roglan
* Discord Usernames  : soupchef_, shilo11
* Creation Date      : 9/6/2026
* Description        : configurable SPI module with FIFO interface ability, single peripheral. 
**********************************************/

module spi_core #(
    parameter int MAX_DATA_WIDTH = 32
)
(
    input  logic clk_i,
    input  logic rstn_i,

    // Core-interface (Valid/Ready Handshake)  can easily add fifo for read and write later
    input  logic tx_valid_i,
    output logic tx_ready_o,        // HIGH when IDLE and ready
    
    output logic [MAX_DATA_WIDTH-1:0] rx_data_o,
    output logic rx_valid_o,        // HIGH when transaction completes
    input  logic rx_ready_i,        // Acknowledge rx_valid_o from possible fifo
    output logic busy_o,            // HIGH while a word is being shifted

    input  logic [MAX_DATA_WIDTH-1:0] tx_data_i,

    // Configuration
    input  logic [20:0] config_bus_i,
    // [0] cpha
    // [1] cpol
    // [2] lsb_first      (1 = LSB first, 0 = MSB first)   //most devices are MSB first
    // [4:3] data_width   (00=4b, 01=8b, 10=16b, 11=32b)
    // [20:5] clock ratio

    // Master-slave interface
    output logic sclk_o,
    output logic mosi_o,
    input  logic miso_i
);

localparam HIGH = 1'b1;
localparam LOW  = 1'b0;

// Configuration unpacking
logic cpha, cpol, lsb_first;
logic [1:0] data_width_sel;
logic [15:0] clk_ratio;

assign cpha = config_bus_i[0];
assign cpol = config_bus_i[1];
assign lsb_first = config_bus_i[2];
assign data_width_sel = config_bus_i[4:3];
assign clk_ratio = config_bus_i[20:5];

// Decode active data width for state machine counter
logic [5:0] active_width;
always_comb begin
    case (data_width_sel)
        2'b00: active_width = 6'd4;
        2'b01: active_width = 6'd8;
        2'b10: active_width = 6'd16;
        2'b11: active_width = 6'd32;
    endcase
end

typedef enum logic {
    IDLE, 
    TRANSFER
} state_t;

state_t state, next_state;

assign busy_o = (state == TRANSFER);

logic [6:0] edge_cnt; 
logic [MAX_DATA_WIDTH-1:0] tx_shift, rx_shift;  //the shift regsiters

logic [14:0] clk_div_cnt;
logic sclk_tick;
logic [15:0] target_count;
assign target_count = (clk_ratio >> 1) - HIGH;

// Clock Divider
always_ff @(posedge clk_i, negedge rstn_i) begin
    if (!rstn_i) begin
        clk_div_cnt <= '0;
        sclk_tick <= LOW;
    end else if (state == TRANSFER) begin
        if (clk_div_cnt >= target_count) begin
            clk_div_cnt <= '0;
            sclk_tick <= HIGH;
        end else begin
            clk_div_cnt <= clk_div_cnt + HIGH;
            sclk_tick <= LOW;
        end
    end else begin
        clk_div_cnt <= '0;
        sclk_tick <= LOW;
    end
end

// Only accept new data if we are IDLE and the previous RX data has been read
assign tx_ready_o = (state == IDLE) && (!rx_valid_o || rx_ready_i);

logic [MAX_DATA_WIDTH-1:0] tx_aligned;   //this is really only for when we do msb first, for lsb we can leave data as is
always_comb begin
    case (data_width_sel)
        2'b00: tx_aligned = tx_data_i << 28; // 4-bit
        2'b01: tx_aligned = tx_data_i << 24; // 8-bit
        2'b10: tx_aligned = tx_data_i << 16; // 16-bit
        2'b11: tx_aligned = tx_data_i;       // 32-bit
    endcase
end

// FSM
always_ff @(posedge clk_i, negedge rstn_i) begin
    if (!rstn_i) begin
        state <= IDLE;
    end else begin
        state <= next_state;
    end
end

always_comb begin
    next_state = state;
    case (state)
        IDLE: begin
            if (tx_valid_i && tx_ready_o) begin
                next_state = TRANSFER;
            end
        end
        TRANSFER: begin
            if (sclk_tick && (edge_cnt == (active_width << 1))) begin
                next_state = IDLE;
            end
        end
    endcase
end

// Datapath
always_ff @(posedge clk_i, negedge rstn_i) begin
    if (!rstn_i) begin
        sclk_o <= LOW;
        mosi_o <= LOW;
        edge_cnt <= '0;
        tx_shift <= '0;
        rx_shift <= '0;
        rx_data_o <= '0;
        rx_valid_o <= LOW;
    end else begin

        // Clear RX valid flag when core handshake occurs
        if (rx_ready_i) begin
            rx_valid_o <= LOW;
        end

        case (state)
            IDLE: begin
                sclk_o <= cpol; // Return SCLK to rest state
                edge_cnt <= '0;
                rx_shift <= '0; // clear so MSB-first words narrower than 32 bits don't carry old bits
                    
                    if (cpha == LOW) begin
                        // CPHA=0: Place data on MOSI before the first clock edge
                        mosi_o <= lsb_first ? tx_data_i[0] : tx_aligned[MAX_DATA_WIDTH-1];
                        
                        if (lsb_first) begin
                             tx_shift <= {1'b0, tx_data_i[31:1]};
                        end
                        else begin        
                            tx_shift <= {tx_aligned[30:0], 1'b0};
                        end
                    end else begin
                        tx_shift <= lsb_first ? tx_data_i : tx_aligned;
                    end
                end

            TRANSFER: begin
                if (sclk_tick) begin
                    if (edge_cnt == (active_width << 1)) begin // ie packet is done
                        
                        if (lsb_first) begin
                            // In LSB-first, data shifted into the top bits must be shifted down because of where we put the data during the shifting
                            case (data_width_sel)
                                2'b00: rx_data_o <= {28'b0, rx_shift[31:28]};
                                2'b01: rx_data_o <= {24'b0, rx_shift[31:24]};
                                2'b10: rx_data_o <= {16'b0, rx_shift[31:16]};
                                2'b11: rx_data_o <= rx_shift;
                            endcase
                        end else begin
                            rx_data_o <= rx_shift;
                        end

                        rx_valid_o <= HIGH;
                        
                    end else begin
                        edge_cnt <= edge_cnt + HIGH;
                        
                        sclk_o <= (edge_cnt[0] == LOW) ? ~cpol : cpol;
                        
                        if (edge_cnt[0] == cpha) begin    //depends on cpha  -- refer to table in documentation page for guidance
                            // Sample MISO
                            if (lsb_first) begin
                                rx_shift <= {miso_i, rx_shift[MAX_DATA_WIDTH-1:1]};
                            end
                            else begin
                                rx_shift <= {rx_shift[MAX_DATA_WIDTH-2:0], miso_i};
                            end
                        end else begin
                            // Update MOSI
                            if (lsb_first) begin
                                mosi_o   <= tx_shift[0];
                                tx_shift <= {1'b0, tx_shift[MAX_DATA_WIDTH-1:1]};
                            end else begin
                                mosi_o   <= tx_shift[MAX_DATA_WIDTH-1];
                                tx_shift <= {tx_shift[MAX_DATA_WIDTH-2:0], LOW};
                            end
                        end
                    end
                end
            end
        endcase
    end
end

endmodule