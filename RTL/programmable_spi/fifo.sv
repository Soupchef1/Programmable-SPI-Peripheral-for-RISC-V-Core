/**********************************************
* Module Name        : fifo
* Authors            : Ryan Karami, Saahas Swaroop, Francis Roglan
* Discord Usernames  : shilo11, soupchef_
* Creation Date      : 9/28/2026
* Description        : fifo module for input and output to the spi 
**********************************************/

module fifo #(
    parameter int DATA_WIDTH = 32,
    parameter int MAX_FIFO_DEPTH = 5
)
(
    input logic clk_i,
    input logic rst_ni,

    // rd- fifo output wr- fifo input
    input logic wr_valid_i,
    output logic wr_ready_o,

    output logic [DATA_WIDTH-1:0] rd_data_o,
    output logic rd_valid_o,
    input logic rd_ready_i,

    input logic [DATA_WIDTH-1:0] wr_data_i,

    // FIFO-sensitive signals
    output logic fifo_full_o,
    output logic fifo_empty_o,
    output logic [$clog2(MAX_FIFO_DEPTH + 1) - 1:0] count_o
);

localparam HIGH = 1'b1;
localparam LOW = 1'b0;
localparam int ADDR_W = $clog2(MAX_FIFO_DEPTH);
localparam int CNT_W = $clog2(MAX_FIFO_DEPTH + 1);

logic wr_en;
logic rd_en;
logic [ADDR_W - 1:0] wr_ptr_q, wr_ptr_d;
logic [ADDR_W - 1:0] rd_ptr_q, rd_ptr_d;
logic [DATA_WIDTH - 1:0] mem_q [MAX_FIFO_DEPTH];
logic [CNT_W - 1:0] count_q, count_d;

assign rd_data_o = mem_q[rd_ptr_q];
assign fifo_empty_o = (count_q == '0);
assign fifo_full_o = (count_q == MAX_FIFO_DEPTH);
assign count_o = count_q;
assign wr_ready_o = !fifo_full_o;
assign rd_valid_o = !fifo_empty_o;
assign wr_en = wr_valid_i && wr_ready_o;
assign rd_en = rd_valid_o && rd_ready_i;

always_ff @(posedge clk_i, negedge rst_ni) begin
    if (!rst_ni) begin
        wr_ptr_q <= '0;
        rd_ptr_q <= '0;
        count_q <= '0;
    end else begin
        wr_ptr_q <= wr_ptr_d;
        rd_ptr_q <= rd_ptr_d;
        count_q <= count_d;
    end
end

always_comb begin
    case ({wr_en, rd_en})
        2'b10: begin
            count_d = count_q + 1'b1;
        end
        2'b01: begin
            count_d = count_q - 1'b1;
        end
        default: begin
            count_d = count_q;
        end
    endcase
    if (wr_en) begin
        if (wr_ptr_q == MAX_FIFO_DEPTH - 1) begin
            wr_ptr_d = '0;
        end else begin
            wr_ptr_d = wr_ptr_q + 1'b1;
        end
    end else begin
        wr_ptr_d = wr_ptr_q;
    end
    if (rd_en) begin
        if (rd_ptr_q == MAX_FIFO_DEPTH - 1) begin
            rd_ptr_d = '0;
        end else begin
            rd_ptr_d = rd_ptr_q + 1'b1;
        end
    end else begin
        rd_ptr_d = rd_ptr_q;
    end
end

always_ff @(posedge clk_i) begin
    if (wr_en) begin
        mem_q[wr_ptr_q] <= wr_data_i;
    end
end


endmodule
