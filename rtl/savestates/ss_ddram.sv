// DDR3 channel for the savestate engine.
// Requests come from clk_sys, the DDR3 port runs on DDRAM_CLK (2x clk_sys, same PLL).

module ss_ddram
(
	input             clk_sys,
	input      [25:0] adr,      // 32-bit word address from the DDR3 base (0x30000000)
	input      [63:0] din,
	input       [7:0] be,
	input             rnw,
	input             req,      // one clk_sys pulse
	output reg        done,     // one clk_sys pulse
	output reg [63:0] dout,

	input             DDRAM_CLK,
	input             DDRAM_BUSY,
	output      [7:0] DDRAM_BURSTCNT,
	output     [28:0] DDRAM_ADDR,
	input      [63:0] DDRAM_DOUT,
	input             DDRAM_DOUT_READY,
	output reg        DDRAM_RD,
	output     [63:0] DDRAM_DIN,
	output      [7:0] DDRAM_BE,
	output reg        DDRAM_WE
);

reg        req_t = 0, ack_t = 0;
reg [25:0] r_adr;
reg [63:0] r_din;
reg  [7:0] r_be;
reg        r_rnw;
reg [63:0] r_dout;
reg        ack_old = 0;
reg        req_old = 0;
reg        busy = 0;
reg        wait_rd = 0;

always @(posedge clk_sys) begin
	done <= 0;
	if (req) begin
		r_adr <= adr;
		r_din <= din;
		r_be  <= be;
		r_rnw <= rnw;
		req_t <= ~req_t;
	end

	ack_old <= ack_t;
	if (ack_old != ack_t) begin
		dout <= r_dout;
		done <= 1;
	end
end

assign DDRAM_BURSTCNT = 1;
assign DDRAM_ADDR     = {4'b0011, r_adr[25:1]};
assign DDRAM_DIN      = r_din;
assign DDRAM_BE       = DDRAM_RD ? 8'hFF : r_be;

always @(posedge DDRAM_CLK) begin
	req_old <= req_t;

	if (!DDRAM_BUSY) begin
		DDRAM_RD <= 0;
		DDRAM_WE <= 0;

		if (!busy && req_old != req_t) begin
			busy <= 1;
			if (r_rnw) begin
				DDRAM_RD <= 1;
				wait_rd  <= 1;
			end
			else begin
				DDRAM_WE <= 1;
			end
		end
		else if (busy && !wait_rd) begin
			busy  <= 0;
			ack_t <= req_t;
		end
	end

	if (wait_rd && DDRAM_DOUT_READY) begin
		r_dout  <= DDRAM_DOUT;
		wait_rd <= 0;
	end
end

endmodule
