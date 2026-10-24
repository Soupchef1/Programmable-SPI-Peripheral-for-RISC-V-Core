/**********************************************
* Module Name        : programmable_spi
* Authors            : Ryan Karami, Saahas Swaroop, Francis Roglan
* Discord Usernames  : soupchef_, shilo11
* Creation Date      : 10/6/2026
* Description        : Memory-mapped SPI master. Wraps spi_core with a TX FIFO, an RX FIFO,
*                      and registers for configuration, status, and chip select lines
**********************************************/
module programmable_spi (
    input  logic        clk_i,
    input  logic        rstn_i,

    // MMIO bus
    input  logic        enable_i,           //one cycle strobe
    input  logic        write_enable_i,     // 1 = write, 0 = read
    input  logic [4:0]  address_i,          // byte address, [1:0] ignored
    input  logic [31:0] write_data_i,
    output logic [31:0] read_data_o,        // registered: valid the cycle after a read
    output logic        read_valid_o,       // high for one cycle when read_data_o is valid

    output logic        interrupt_request_o,

    // SPI pins
    output logic        sclk_o,
    output logic [3:0]  chip_select_n_o,    // to GPIO
    output logic        mosi_o,
    input  logic        miso_i
);

localparam int FIFO_DEPTH = 8;
localparam int DATA_WIDTH = 32;
localparam int COUNT_WIDTH = $clog2(FIFO_DEPTH + 1);

// Register index = address_i[4:2]
typedef enum logic [2:0] {
    REG_CONFIG,         // 0x00
    REG_CHIP_SELECT,    // 0x04
    REG_TX_DATA,        // 0x08
    REG_RX_DATA,        // 0x0C
    REG_STATUS,         // 0x10
    REG_IRQ_ENABLE      // 0x14
} register_t;

// Bits [20:0] match spi_core's config_bus_i
typedef struct packed {
    logic receive_enable;
    logic [15:0] clock_ratio;
    logic [1:0]  word_width;
    logic lsb_first;
    logic cpol;
    logic cpha;
} config_t;

localparam logic HIGH = 1'b1;
localparam logic LOW = 1'b0;
localparam config_t CONFIG_RESET = '{receive_enable: HIGH, clock_ratio: 16'd4, word_width: 2'b01,
                                     lsb_first: LOW, cpol: LOW, cpha: LOW};

config_t config_register;           // CONFIG as written by software
config_t config_active;             // CONFIG the core uses, only updated when transfer_done
config_t config_write_value;        // what a CONFIG write stores (cpol protected)
logic [3:0] chip_select_register;
logic [3:0] irq_enable;
logic error;                        // a write or read was dropped or ignored
logic transfer_done;

register_t selected_register;
logic register_write, register_read;
logic cpol_change_allowed, access_error;
logic [31:0] read_data_next;

logic tx_fifo_write_ready, tx_fifo_full, tx_fifo_empty;
logic rx_fifo_read_valid, rx_fifo_full, rx_fifo_empty;
logic [COUNT_WIDTH-1:0] tx_fifo_count, rx_fifo_count;
logic [31:0] rx_fifo_data, spi_tx_data, spi_rx_data;
logic spi_tx_valid, spi_tx_ready, spi_rx_valid, spi_rx_fifo_ready, spi_busy;

// Bus decode for addr
assign selected_register = register_t'(address_i[4:2]);
assign register_write = enable_i && write_enable_i;
assign register_read = enable_i && !write_enable_i;

// TX FIFO empty, core idle, last RX word stored
assign transfer_done = tx_fifo_empty && !spi_busy && !spi_rx_valid;

// cpol only changes when idle and deselected, and config_active takes it on the same
// edge, so SCLK settles a cycle before a following CS write reaches the (registered) pins.
assign cpol_change_allowed = transfer_done && (chip_select_register == 4'hF);
assign config_write_value = '{receive_enable: write_data_i[21], clock_ratio: write_data_i[20:5],
                              word_width: write_data_i[4:3], lsb_first: write_data_i[2],
                              cpol: cpol_change_allowed ? write_data_i[1] : config_register.cpol,
                              cpha: write_data_i[0]};

// An access software expected to work was dropped or ignored
always_comb begin
    access_error = LOW;
    if (register_write) begin
        case (selected_register)
            REG_CONFIG: access_error = (write_data_i[1] != config_write_value.cpol);
            REG_CHIP_SELECT: access_error = !transfer_done && (write_data_i[3:0] != chip_select_register);
            REG_TX_DATA: access_error = !tx_fifo_write_ready;
            default: ;
        endcase
    end else if (register_read && selected_register == REG_RX_DATA) begin
        access_error = !rx_fifo_read_valid;
    end
end

assign interrupt_request_o = |(irq_enable & {error, !rx_fifo_empty, tx_fifo_empty, transfer_done});

always_ff @(posedge clk_i, negedge rstn_i) begin
    if (!rstn_i) begin
        config_register <= CONFIG_RESET;
        config_active <= CONFIG_RESET;
        chip_select_register <= 4'hF;
        chip_select_n_o <= 4'hF;
        irq_enable <= '0;
        error <= LOW;
        read_data_o <= '0;
        read_valid_o <= LOW;
    end else begin
        if (register_write) begin
            case (selected_register)
                REG_CONFIG: config_register <= config_write_value;
                // CS changes mid-transfer would break the transaction, so they are ignored
                REG_CHIP_SELECT: if (transfer_done) chip_select_register <= write_data_i[3:0];
                REG_IRQ_ENABLE: irq_enable <= write_data_i[3:0];
                default: ;
            endcase
        end

        // The core only picks up CONFIG between transfers. A write while idle applies at once.
        if (transfer_done) begin
            config_active <= (register_write && selected_register == REG_CONFIG) ?
                             config_write_value : config_register;
        end

        // Any write to STATUS clears error.
        if (access_error) begin
            error <= HIGH;
        end else if (register_write && selected_register == REG_STATUS) begin
            error <= LOW;
        end

        chip_select_n_o <= chip_select_register;

        read_valid_o <= register_read;
        if (register_read) begin
            read_data_o <= read_data_next;
        end
    end
end

// Read mux
always_comb begin
    read_data_next = '0;
    case (selected_register)
        REG_CONFIG: read_data_next[21:0] = config_register;
        REG_CHIP_SELECT: read_data_next[3:0] = chip_select_register;
        REG_RX_DATA: read_data_next = rx_fifo_read_valid ? rx_fifo_data : '0;
        REG_STATUS: read_data_next = {8'(rx_fifo_count), 8'(tx_fifo_count), error,
                                      config_register != config_active,   // config_pending
                                      transfer_done, rx_fifo_empty, rx_fifo_full,
                                      tx_fifo_empty, tx_fifo_full, spi_busy};
        REG_IRQ_ENABLE: read_data_next[3:0] = irq_enable;
        default: ;
    endcase
end


fifo #(
    .DATA_WIDTH (DATA_WIDTH),
    .MAX_FIFO_DEPTH (FIFO_DEPTH)
) u_tx_fifo (
    .clk_i (clk_i),
    .rst_ni (rstn_i),
    .wr_valid_i (register_write && selected_register == REG_TX_DATA),   // dropped when full
    .wr_ready_o (tx_fifo_write_ready),
    .wr_data_i (write_data_i),
    .rd_data_o (spi_tx_data),
    .rd_valid_o (spi_tx_valid),
    .rd_ready_i (spi_tx_ready),
    .fifo_full_o (tx_fifo_full),
    .fifo_empty_o (tx_fifo_empty),
    .count_o (tx_fifo_count)
);

// With receive_enable = 1 the core's word is only taken when there is room
fifo #(
    .DATA_WIDTH (DATA_WIDTH),
    .MAX_FIFO_DEPTH (FIFO_DEPTH)
) u_rx_fifo (
    .clk_i (clk_i),
    .rst_ni (rstn_i),
    .wr_valid_i (spi_rx_valid && config_active.receive_enable),
    .wr_ready_o (spi_rx_fifo_ready),
    .wr_data_i (spi_rx_data),
    .rd_data_o (rx_fifo_data),
    .rd_valid_o (rx_fifo_read_valid),
    .rd_ready_i (register_read && selected_register == REG_RX_DATA),    // pop on read
    .fifo_full_o (rx_fifo_full),
    .fifo_empty_o (rx_fifo_empty),
    .count_o (rx_fifo_count)
);

spi_core #(
    .MAX_DATA_WIDTH (DATA_WIDTH)
) u_spi_core (
    .clk_i (clk_i),
    .rstn_i (rstn_i),
    .tx_valid_i (spi_tx_valid),
    .tx_ready_o (spi_tx_ready),
    .tx_data_i (spi_tx_data),
    .rx_data_o (spi_rx_data),
    .rx_valid_o (spi_rx_valid),
    .rx_ready_i (!config_active.receive_enable || spi_rx_fifo_ready),
    .busy_o (spi_busy),
    .config_bus_i (config_active[20:0]),
    .sclk_o (sclk_o),
    .mosi_o (mosi_o),
    .miso_i (miso_i)
);

endmodule
