// Test of ss_cd: models of Main's CD drive, the SCSI FIFO of the core,
// the savestate engine, DDR3, the save file and the backup RAM logic.
// built with Verilator, see run.sh

`timescale 1ns/1ns

module dpram #(parameter addr_width=8, data_width=8, mem_init_file=" ", disable_value=1)
(
	input clock,
	input [addr_width-1:0] address_a, input [data_width-1:0] data_a, input enable_a, input wren_a, output reg [data_width-1:0] q_a, input cs_a,
	input [addr_width-1:0] address_b, input [data_width-1:0] data_b, input enable_b, input wren_b, output reg [data_width-1:0] q_b, input cs_b
);
reg [data_width-1:0] m[2**addr_width];
always @(posedge clock) begin
	if (wren_a) m[address_a] <= data_a;
	q_a <= wren_a ? data_a : m[address_a];
end
always @(posedge clock) begin
	if (wren_b) m[address_b] <= data_b;
	q_b <= wren_b ? data_b : m[address_b];
end
endmodule

module eReg_SavestateV #(parameter [9:0] Adr=0, parameter [63:0] def=0)
(
	input clk, input [63:0] BUS_Din, input [9:0] BUS_Adr, input BUS_wren, input BUS_rst, output [63:0] BUS_Dout, input [63:0] Din, output reg [63:0] Dout = def
);
assign BUS_Dout = (BUS_Adr == Adr) ? Din : 64'd0;
always @(posedge clk) begin
	if (BUS_rst) Dout <= def;
	else if (BUS_wren && BUS_Adr == Adr) Dout <= BUS_Din;
end
endmodule

module tb;

localparam GAP    = 30000;
localparam TICK   = 10000;      // Main's 13.33 ms
localparam REFILL = 2000000;
localparam [31:0] SIZE_CD = 148800;
localparam [25:0] BUF = 26'h3900000;

reg clk = 0;
always #1 clk = ~clk;

integer errors = 0;
`define CHECK(c, msg) if (!(c)) begin errors = errors + 1; $display("ERROR %0t: %s", $time, msg); end

reg         reset = 0;
reg         cd_mode = 1, ac_mode = 0;
reg         scsi_reset = 0;
reg         save = 0, load = 0;
reg   [1:0] slot = 0;
wire        busy, info_req;
wire  [7:0] info;
wire        eng_save, eng_load, hold, fifo_clr;
reg         eng_busy = 0, eng_load_done = 0, eng_restore = 0;
reg         paused = 0;
wire        core_run;
reg  [63:0] bus_din = 0;
reg   [9:0] bus_adr = 0;
reg         bus_wren = 0, bus_rst = 0;
wire [63:0] bus_dout;
reg  [95:0] comm = 0;
reg         comm_ev = 0, dataout_ev = 0, reset_ev = 0;
reg         code2_ev = 0;
wire        msg_ev = comm_ev | reset_ev | code2_ev;
wire        block_out, inj_req;
wire[111:0] inj_data;
reg         stat_ev = 0;
reg  [15:0] stat_in = 0;
reg         dout_ev = 0;
wire        stat_get, dout_req;
wire [15:0] stat_out;
reg         pkt_hdr = 0;
reg   [1:0] pkt_ch = 0;
reg  [14:0] pkt_len = 0;
reg         byte_wr = 0;
reg  [14:0] byte_idx = 0;
reg   [7:0] byte_val = 0;
wire        drop;
reg         scsi_rd = 0;
wire        ddr_owner, ddr_rnw, ddr_req;
wire [25:0] ddr_adr;
wire [63:0] ddr_din;
reg         ddr_done = 0;
reg  [63:0] ddr_dout = 0;
reg         mounting = 0;
reg  [63:0] img_size = 0;
wire        bk_force;
reg         bk_busy = 0;
wire        sd_act, sd_rd, sd_wr;
wire [31:0] sd_lba;
wire  [5:0] sd_blk_cnt;
reg         sd_ack = 0;
reg  [12:0] sd_buff_addr = 0;
reg  [15:0] sd_buff_dout = 0;
wire [15:0] sd_buff_din;
reg         sd_buff_wr = 0;

reg  [31:0] bk_lba = 0;
reg         bk_rd = 0, bk_wr = 0;
wire        hps_wr  = sd_act ? sd_wr : bk_wr;
wire        hps_rd  = sd_act ? sd_rd : bk_rd;
wire [31:0] hps_lba = sd_act ? sd_lba : bk_lba;
wire  [5:0] hps_blks = sd_act ? sd_blk_cnt : 6'd0;

wire freeze_req = eng_busy | hold;
always @(posedge clk) paused <= freeze_req;
assign core_run = ~freeze_req & ~paused;

ss_cd #(.GAP(GAP), .REFILL(REFILL)) dut
(
	.clk(clk), .reset(reset), .cd_mode(cd_mode), .ac_mode(ac_mode),
	.save(save), .load(load), .slot(slot), .busy(busy), .info_req(info_req), .info(info),
	.eng_save(eng_save), .eng_load(eng_load), .eng_busy(eng_busy), .eng_load_done(eng_load_done), .eng_restore(eng_restore),
	.hold(hold), .paused(paused), .core_run(core_run), .fifo_clr(fifo_clr),
	.bus_din(bus_din), .bus_adr(bus_adr), .bus_wren(bus_wren), .bus_rst(bus_rst), .bus_dout(bus_dout),
	.comm(comm), .comm_ev(comm_ev), .dataout_ev(dataout_ev), .reset_ev(reset_ev), .msg_ev(msg_ev), .block_out(block_out), .inj_req(inj_req), .inj_data(inj_data),
	.stat_ev(stat_ev), .stat_in(stat_in), .dout_ev(dout_ev), .stat_get(stat_get), .stat_out(stat_out), .dout_req(dout_req),
	.pkt_hdr(pkt_hdr), .pkt_ch(pkt_ch), .pkt_len(pkt_len), .byte_wr(byte_wr), .byte_idx(byte_idx), .byte_val(byte_val), .drop(drop), .scsi_rd(scsi_rd), .scsi_reset(scsi_reset),
	.ddr_owner(ddr_owner), .ddr_adr(ddr_adr), .ddr_din(ddr_din), .ddr_rnw(ddr_rnw), .ddr_req(ddr_req), .ddr_done(ddr_done), .ddr_dout(ddr_dout),
	.mounting(mounting), .img_size(img_size), .hps_wr(hps_wr), .hps_lba(hps_lba), .hps_blks(hps_blks),
	.bk_force(bk_force), .bk_busy(bk_busy),
	.sd_act(sd_act), .sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr)
);

//----------------------------------------------------------------------------
// DDR3: 32-bit words, sparse

reg [31:0] ddr [int unsigned];

function [31:0] ddr_rd32(input [25:0] a);
	ddr_rd32 = ddr.exists(a) ? ddr[a] : 32'hDEADBEEF;
endfunction

always @(posedge clk) begin
	reg [3:0] dly;
	ddr_done <= 0;
	if (ddr_req) begin
		`CHECK(ddr_owner, "DDR request without owner")
		if (ddr_rnw) ddr_dout <= {ddr_rd32(ddr_adr + 1), ddr_rd32(ddr_adr)};
		else begin
			ddr[ddr_adr]     = ddr_din[31:0];
			ddr[ddr_adr + 1] = ddr_din[63:32];
		end
		dly <= 5;
	end
	else if (dly) begin
		dly <= dly - 1'd1;
		if (dly == 1) ddr_done <= 1;
	end
end

//----------------------------------------------------------------------------
// save file, with Main's rules

reg [7:0] file [int unsigned];
longint   file_size = 0;
reg       file_exists = 0;

task automatic sd_op(input bit wr, input [31:0] lba, input [5:0] blks);
	int n = (blks + 1) * 256;
	reg [15:0] w [];
	w = new[n];
	sd_ack <= 1;
	@(posedge clk);
	if (!wr) begin
		for (int i = 0; i < n; i++) begin
			longint a = longint'(lba) * 512 + i * 2;
			w[i] = {file.exists(a+1) && a+1 < file_size ? file[a+1] : 8'h00, file.exists(a) && a < file_size ? file[a] : 8'h00};
			sd_buff_addr <= i;
			sd_buff_dout <= w[i];
			sd_buff_wr <= 1;
			@(posedge clk);
			sd_buff_wr <= 0;
			@(posedge clk);
		end
	end
	else begin
		for (int i = 0; i < n; i++) begin
			sd_buff_addr <= i;
			@(posedge clk);
			@(posedge clk);
			w[i] = sd_buff_din;
		end
		if ((!file_exists && lba == 0) || (file_exists && lba <= file_size / 512)) begin
			file_exists = 1;
			for (int i = 0; i < n; i++) begin
				longint a = longint'(lba) * 512 + i * 2;
				file[a] = w[i][7:0];
				file[a+1] = w[i][15:8];
			end
			if (longint'(lba) * 512 + n * 2 > file_size) file_size = longint'(lba) * 512 + n * 2;
		end
		else $display("NOTE %0t: Main drops a write at block %0d, file has %0d blocks", $time, lba, file_size / 512);
	end
	sd_ack <= 0;
	repeat (20) @(posedge clk);
endtask

initial begin
	forever begin
		@(posedge clk);
		if (hps_rd || hps_wr) begin
			repeat (10) @(posedge clk);
			sd_op(hps_wr, hps_lba, hps_blks);
		end
	end
end

// backup RAM logic: writes blocks 0..3
initial begin
	forever begin
		@(posedge clk);
		if (bk_force) begin
			bk_busy <= 1;
			for (int b = 0; b < 4; b++) begin
				bk_lba <= b;
				bk_wr <= 1;
				@(posedge clk);
				wait (sd_ack);
				@(posedge clk);
				bk_wr <= 0;
				wait (!sd_ack);
				@(posedge clk);
			end
			bk_busy <= 0;
		end
	end
end

//----------------------------------------------------------------------------
// the core: SCSI FIFO read by the CPU

byte unsigned fifo[$];
byte unsigned got[$];     // bytes read by the CPU
int           stats = 0;  // statuses received
bit           in_data = 0;
int           rd_div = 0;
int           rd_rate = 6;
bit           core_cmd_waiting = 0;
bit           core_pulse = 0;

typedef struct { int got_n; int stats; bit in_data; } core_state_t;

// messages of the core to Main
reg [111:0] msgq[$];
bit         msginj[$];   // the message comes from ss_cd
always @(posedge clk) begin
	scsi_rd <= 0;
	code2_ev <= 0;
	if (byte_wr && pkt_ch == 1 && !drop) fifo.push_back(byte_val);
	if (fifo_clr || scsi_reset) fifo.delete();
	if (stat_get) stats++;
	if (core_run) begin
		rd_div++;
		if (rd_div >= rd_rate) begin
			rd_div = 0;
			if (fifo.size()) begin
				got.push_back(fifo.pop_front());
				scsi_rd <= 1;
				in_data = 1;
			end
			else if (in_data) begin
				// CD_DATA_END
				in_data = 0;
				if (!block_out) begin msgq.push_back({16'h0002, 96'd0}); msginj.push_back(0); code2_ev <= 1; end
			end
		end
	end
end

task automatic core_cmd(input [95:0] c);
	repeat (5000) @(posedge clk);
	wait (core_run);
	@(posedge clk);
	comm <= c;
	comm_ev <= 1;
	msgq.push_back({16'h8000, c});
	msginj.push_back(0);
	@(posedge clk);
	comm_ev <= 0;
endtask

//----------------------------------------------------------------------------
// Main's drive

localparam ST_IDLE = 0, ST_READ = 1, ST_PLAY = 2, ST_PAUSE = 3;
int  m_state = ST_IDLE;
int  m_lba = 0, m_cnt = 0, m_latency = 0, m_end = 0, m_mode = 0, m_start = 0;
bit  m_can_read = 0, m_has_stat = 0, m_int = 0, m_subq = 0;
int  last_msg_time = -1000000;
int  inj_log[$];          // commands sent, for the checks
reg [95:0] inj_cmds[$];

function automatic byte unsigned sector_byte(int lba, int i);
	return byte'((lba * 7 + i * 13 + (i >> 8)) & 255);
endfunction

always @(posedge clk) if (inj_req) begin msgq.push_back(inj_data); msginj.push_back(1); end

task automatic send_pkt(input [1:0] ch, input int len, input int lba, input bit subq);
	pkt_hdr <= 1;
	pkt_ch  <= ch;
	pkt_len <= len;
	@(posedge clk);
	pkt_hdr <= 0;
	for (int i = 0; i < len; i++) begin
		byte unsigned v;
		if (ch == 1) v = subq ? byte'(i + 1) : sector_byte(lba, i);
		else if (ch == 3) begin
			// subcode: Q (bit 6) carries absolute MSF of lba in Q bytes 7..9
			int a = lba + 150;
			int m = a / 4500, s = (a / 75) % 60, f = a % 75;
			reg [95:0] q = {8'h01, 8'h01, 8'h01, 24'd0, 8'd0, {4'(m/10), 4'(m%10)}, {4'(s/10), 4'(s%10)}, {4'(f/10), 4'(f%10)}, 16'd0};
			v = (i >= 2) ? {1'b0, q[95 - (i - 2)], 6'd0} : 8'h00;
		end
		else v = 8'h55;
		byte_idx <= i;
		byte_val <= v;
		byte_wr  <= 1;
		@(posedge clk);
		byte_wr  <= 0;
		@(posedge clk);
	end
endtask

task automatic send_stat();
	stat_in <= 16'h0000;
	stat_ev <= 1;
	@(posedge clk);
	stat_ev <= 0;
endtask

task automatic m_exec(input [111:0] msg, input bit inj);
	reg [7:0] code = msg[103:96];
	reg [95:0] c = msg[95:0];
	bit fast = msg[111];
	if (inj && $time - last_msg_time < 4000) begin
		errors++;
		$display("ERROR %0t: two messages to Main too close, one would be lost", $time);
	end
	last_msg_time = $time;
	if (code == 8'hFF) begin
		m_state = ST_IDLE; m_has_stat = 0; m_can_read = 0; m_int = 0; m_subq = 0;
		return;
	end
	if (code == 8'h02) begin m_can_read = 1; return; end
	if (code == 8'h01) begin send_stat(); return; end
	m_int = 0;
	case (c[7:0])
		8'h08: begin
			m_lba = {c[12:8], c[23:16], c[31:24]};
			m_cnt = c[39:32] ? c[39:32] : 256;
			m_latency = fast ? 0 : 3;
			m_can_read = 1;
			m_state = ST_READ;
		end
		8'hD8: begin
			m_lba = {c[31:24], c[39:32], c[47:40]};
			m_start = m_lba;
			m_end = 400000;
			m_mode = c[15:8];
			m_latency = fast ? 0 : 3;
			m_state = m_mode ? ST_PLAY : ST_PAUSE;
			m_has_stat = 1;
		end
		8'hD9: begin
			m_end = (c[79:72] == 8'h80) ? 400000 : {c[31:24], c[39:32], c[47:40]};
			m_mode = c[15:8];
			m_state = m_mode ? ST_PLAY : ST_IDLE;
			if (m_mode == 2) m_int = 1;
			else send_stat();
		end
		8'hDA: begin m_state = ST_PAUSE; send_stat(); end
		8'hDD: m_subq = 1;
		default: send_stat();
	endcase
endtask

initial begin
	int t = 0;
	forever begin
		@(posedge clk);
		t++;
		if (msgq.size()) m_exec(msgq.pop_front(), msginj.pop_front());
		if (t >= TICK) begin
			t = 0;
			if (m_has_stat && !m_latency) begin send_stat(); m_has_stat = 0; end
			case (m_state)
				ST_READ: begin
					if (m_latency) m_latency--;
					else if (m_lba < 64) begin
						// audio track: nothing is sent
						m_cnt--;
						m_lba++;
						if (!m_cnt) begin m_has_stat = 1; m_state = ST_IDLE; end
					end
					else if (m_can_read) begin
						m_can_read = 0;
						send_pkt(1, 2048, m_lba, 0);
						m_cnt--;
						m_lba++;
						if (!m_cnt) begin m_has_stat = 1; m_state = ST_IDLE; end
					end
				end
				ST_PLAY: begin
					if (m_latency) m_latency--;
					else begin
						send_pkt(2, 16, m_lba, 0);
						send_pkt(3, 98, m_lba, 0);
						m_lba++;
						if (m_lba > m_end) begin
							if (m_mode == 1) m_lba = m_start;
							else m_state = ST_IDLE;
							if (m_int) begin send_stat(); m_int = 0; end
						end
					end
				end
				ST_PAUSE: begin
					send_pkt(3, 98, m_lba, 0);
					if (m_latency) m_latency--;
				end
				default:;
			endcase
			if (m_subq) begin
				m_subq = 0;
				send_pkt(1, 10, 0, 1);
				send_stat();
			end
		end
	end
end

// commands ss_cd sends
always @(posedge clk) if (inj_req && inj_data[103:96] == 0) inj_cmds.push_back(inj_data[95:0]);

//----------------------------------------------------------------------------
// savestate engine: registers 80..85 and the core model go in DDR3

core_state_t saved_core;
reg [63:0]   eng_regs[80:85];

always @(posedge clk) begin
	if (eng_save) fork eng_do_save(); join_none
	if (eng_load) fork eng_do_load(); join_none
end

task automatic eng_do_save();
	eng_busy <= 1;
	@(posedge clk);
	wait (paused);
	repeat (50) @(posedge clk);
	for (int r = 80; r <= 85; r++) begin
		bus_adr <= r;
		@(posedge clk);
		@(posedge clk);
		ddr[BUF + 2 + (r - 80) * 2]     = bus_dout[31:0];
		ddr[BUF + 2 + (r - 80) * 2 + 1] = bus_dout[63:32];
	end
	bus_adr <= 127;
	ddr[BUF + 20] = got.size();
	ddr[BUF + 21] = stats;
	ddr[BUF + 22] = in_data;
	for (int i = 23; i < SIZE_CD + 2; i++) ddr[BUF + i] = i * 32'h01000193 ^ 32'h5A5A0000;
	ddr[BUF]     = 1;
	ddr[BUF + 1] = SIZE_CD;
	repeat (20) @(posedge clk);
	eng_busy <= 0;
endtask

int load_bad = 0;
task automatic eng_do_load();
	eng_busy <= 1;
	@(posedge clk);
	wait (paused);
	repeat (50) @(posedge clk);
	if (ddr_rd32(BUF + 1) != SIZE_CD) begin
		eng_busy <= 0;
		return;
	end
	for (int r = 80; r <= 85; r++) begin
		bus_adr  <= r;
		bus_din  <= {ddr_rd32(BUF + 2 + (r - 80) * 2 + 1), ddr_rd32(BUF + 2 + (r - 80) * 2)};
		bus_wren <= 1;
		@(posedge clk);
		bus_wren <= 0;
		@(posedge clk);
	end
	bus_adr <= 127;
	load_bad = 0;
	for (int i = 23; i < SIZE_CD + 2; i++) if (ddr_rd32(BUF + i) != (i * 32'h01000193 ^ 32'h5A5A0000)) load_bad++;
	// the core takes its saved state
	while (got.size() > ddr_rd32(BUF + 20)) void'(got.pop_back());
	stats   = ddr_rd32(BUF + 21);
	in_data = ddr_rd32(BUF + 22);
	eng_restore <= 1;
	@(posedge clk);
	eng_restore <= 0;
	repeat (10) @(posedge clk);
	eng_load_done <= 1;
	eng_busy <= 0;
	@(posedge clk);
	eng_load_done <= 0;
endtask

//----------------------------------------------------------------------------
// test

int last_info = 0;
always @(posedge clk) if (info_req) begin last_info = info; $display("%0t: info %0d", $time, info); end

task automatic do_save(input [1:0] s);
	@(posedge clk);
	slot <= s; save <= 1;
	@(posedge clk);
	save <= 0;
	wait (busy);
	wait (!busy);
	run(5);
endtask

task automatic do_load(input [1:0] s);
	@(posedge clk);
	slot <= s; load <= 1;
	@(posedge clk);
	load <= 0;
	wait (busy);
	wait (!busy);
	run(5);
endtask

task automatic run(input int n);
	repeat (n) @(posedge clk);
endtask

function automatic bit check_read(int lba0, int n, string name);
	int bad = 0;
	if (got.size() != n * 2048) begin
		$display("ERROR %s: %0d bytes read, expected %0d", name, got.size(), n * 2048);
		errors++;
		return 0;
	end
	for (int i = 0; i < n * 2048; i++) if (got[i] != sector_byte(lba0 + i / 2048, i % 2048)) bad++;
	if (bad) begin $display("ERROR %s: %0d wrong bytes", name, bad); errors++; end
	return bad == 0;
endfunction

initial begin
	int g;
	reset <= 1;
	run(10);
	reset <= 0;
	// a new game: no save file yet
	mounting <= 1; img_size <= 0;
	run(1);
	mounting <= 0;
	run(100);

	//------------------------------------------------------------------ 1
	$display("--- 1: save in the middle of a sector, load");
	core_cmd({56'd0, 8'd4, 8'd100, 8'd0, 8'd0, 8'h08});   // READ6 lba 100, 4 sectors
	wait (got.size() >= 2048 + 700);
	do_save(0);
	`CHECK(last_info == 14, "save not done")
	`CHECK(file_size >= (32'h200 + 1163) * 512, "slot 0 not in the file")
	g = 0;
	for (int i = 0; i < (SIZE_CD + 2) * 4; i++) begin
		longint a = 32'h200 * 512 + i;
		reg [31:0] w = ddr_rd32(BUF + i / 4);
		if (file[a] != w[(i % 4) * 8 +: 8]) g++;
	end
	`CHECK(g == 0, "file content differs from the buffer")
	wait (stats == 1);
	run(3 * TICK);
	void'(check_read(100, 4, "1 without load"));
	// now back
	for (int i = 0; i < SIZE_CD + 2; i++) ddr[BUF + i] = 0;   // the buffer must come from the file
	inj_cmds.delete();
	do_load(0);
	`CHECK(last_info == 15, "load not done")
	`CHECK(load_bad == 0, "state from the file differs")
	wait (stats == 1);
	run(3 * TICK);
	void'(check_read(100, 4, "1 after load"));
	`CHECK(stats == 1, "status count")
	$display("commands: %0d, first %h", inj_cmds.size(), inj_cmds.size() ? inj_cmds[0] : 0);

	//------------------------------------------------------------------ 2
	$display("--- 2: save after the last sector, before its status");
	got.delete(); stats = 0;
	core_cmd({56'd0, 8'd2, 8'd200, 8'd0, 8'd0, 8'h08});
	wait (got.size() == 2 * 2048);
	run(rd_rate * 4);
	do_save(1);
	`CHECK(last_info == 14, "save 2")
	wait (stats == 1);
	run(2 * TICK);
	do_load(1);
	`CHECK(last_info == 15, "load 2")
	run(4 * TICK);
	void'(check_read(200, 2, "2 after load"));
	`CHECK(stats == 1, "status 2 count")

	//------------------------------------------------------------------ 3
	$display("--- 3: save while seeking, before any sector");
	got.delete(); stats = 0;
	core_cmd({56'd0, 8'd3, 8'd50, 8'd1, 8'd0, 8'h08});   // lba 0x01_32
	run(10);
	do_save(2);
	wait (stats == 1);
	run(2 * TICK);
	do_load(2);
	wait (stats == 1);
	run(4 * TICK);
	void'(check_read(306, 3, "3 after load"));
	`CHECK(stats == 1, "status 3 count")

	//------------------------------------------------------------------ 4
	$display("--- 4: CD audio");
	got.delete(); stats = 0;
	core_cmd({40'd0, 8'h00, 8'd0, 8'd0, 8'd0, 8'd0, 8'd0, 8'h00, 8'd0, 8'h00, 8'h00, 8'hD8}); // SAPSP lba 0, silent
	wait (stats == 1);
	core_cmd({40'd0, 8'h00, 8'd0, 8'd0, 8'd0, 8'd0, 8'h01, 8'h86, 8'h00, 8'h00, 8'h03, 8'hD9}); // SAPEP lba 0x186A0, normal
	wait (stats == 2);
	run(20 * TICK);
	$display("4: drv %0d sapep_valid %0d sub %0d/%0d", dut.drv, dut.sapep_valid, dut.sub_lba, dut.sub_valid);
	do_save(3);
	$display("4: saved r81 %h r85 %h", ddr_rd32(BUF+2+3)<<0, ddr_rd32(BUF+2+10));
	run(30 * TICK);
	inj_cmds.delete();
	do_load(3);
	`CHECK(stats == 2, "status 4 count")
	foreach (inj_cmds[i]) $display("4: command %h", inj_cmds[i]);
	`CHECK(inj_cmds.size() == 2, "4: two commands expected")
	if (inj_cmds.size() == 2) begin
		int l = {inj_cmds[0][31:24], inj_cmds[0][39:32], inj_cmds[0][47:40]};
		$display("4: SAPSP %h (lba %0d), SAPEP %h", inj_cmds[0], l, inj_cmds[1]);
		`CHECK(inj_cmds[0][7:0] == 8'hD8 && l >= 17 && l <= 22, "4: position")
		`CHECK(inj_cmds[1] == {40'd0, 8'h00, 8'd0, 8'd0, 8'd0, 8'd0, 8'h01, 8'h86, 8'h00, 8'h00, 8'h03, 8'hD9}, "4: end")
	end
	`CHECK(m_state == ST_PLAY, "4: playing")
	run(5 * TICK);
	`CHECK(stats == 2, "status 4 count after")

	//------------------------------------------------------------------ 5
	$display("--- 5: READ SUBQ answer half read");
	core_cmd({88'd0, 8'hDA});   // pause
	wait (stats == 3);
	got.delete(); stats = 0;
	rd_rate = 2000;
	core_cmd({88'd0, 8'hDD});
	wait (got.size() == 4);
	do_save(0);
	rd_rate = 6;
	wait (stats == 1);
	run(2 * TICK);
	`CHECK(got.size() == 10, "5: 10 bytes")
	rd_rate = 6;
	inj_cmds.delete();
	do_load(0);
	foreach (inj_cmds[i]) $display("5: command %h", inj_cmds[i]);
	$display("5: got %0d stats %0d res_k %0d drop_k %0d", got.size(), stats, dut.res_k, dut.drop_k);
	wait (stats == 1);
	run(2 * TICK);
	$display("5: got %0d", got.size());
	`CHECK(got.size() == 10, "5: 10 bytes after load")
	for (int i = 0; i < got.size(); i++) `CHECK(got[i] == i + 1, "5: answer bytes")

	//------------------------------------------------------------------ 7
	$display("--- 7: last sector half read, its status already given");
	core_cmd({88'd0, 8'h00});   // test unit ready, for the gap
	run(2 * TICK);
	got.delete(); stats = 0;
	rd_rate = 12;
	core_cmd({56'd0, 8'd2, 8'd10, 8'd2, 8'd0, 8'h08});   // lba 0x20A
	wait (got.size() >= 2048 + 1500);
	`CHECK(stats == 1, "7: status before the end of the data")
	do_save(1);
	wait (got.size() == 4096);
	run(2 * TICK);
	void'(check_read(522, 2, "7 without load"));
	do_load(1);
	run(4 * TICK);
	void'(check_read(522, 2, "7 after load"));
	`CHECK(stats == 1, "status 7 count")
	rd_rate = 6;

	//------------------------------------------------------------------ 8
	$display("--- 8: SCSI reset with bytes in the FIFO, then save and load");
	got.delete(); stats = 0;
	rd_rate = 30;
	core_cmd({56'd0, 8'd3, 8'd0, 8'd3, 8'd0, 8'h08});   // lba 0x300, 3 sectors
	wait (got.size() >= 500);
	// the game aborts the read
	@(posedge clk);
	scsi_reset <= 1;
	reset_ev <= 1;
	msgq.push_back({16'h00FF, 96'd0});
	msginj.push_back(0);
	@(posedge clk);
	reset_ev <= 0;
	run(100);
	scsi_reset <= 0;
	rd_rate = 6;
	run(3 * TICK);
	g = got.size();
	`CHECK(dut.fifo_cnt == 0, "8: FIFO count after the SCSI reset")
	do_save(2);
	do_load(2);
	run(4 * TICK);
	`CHECK(got.size() == g, "8: bytes after the load")
	core_cmd({56'd0, 8'd1, 8'd20, 8'd3, 8'd0, 8'h08});  // a new read, lba 0x314
	wait (stats == 1);
	run(2 * TICK);
	for (int i = 0; i < 2048; i++) if (got[g + i] != sector_byte(32'h314, i)) begin errors++; $display("ERROR 8: new read wrong at %0d", i); break; end

	//------------------------------------------------------------------ 9
	$display("--- 9: CD audio in a loop");
	got.delete(); stats = 0;
	core_cmd({48'd0, 8'd5, 8'd0, 8'd0, 8'd0, 8'h00, 8'hD8}); // SAPSP lba 5, silent
	wait (stats == 1);
	core_cmd({48'd0, 8'd40, 8'd0, 8'd0, 8'd0, 8'h01, 8'hD9}); // SAPEP lba 40, loop
	wait (stats == 2);
	run(50 * TICK);   // 5..40, then again from 5
	$display("9: sub %0d", dut.sub_lba);
	g = dut.sub_lba;
	do_save(0);
	// the drive was stopped for the copy, and goes on from where it was
	$display("9: after the save Main at %0d, loop start %0d", m_lba, m_start);
	`CHECK(m_state == ST_PLAY && m_start == 5 && m_lba >= g && m_lba <= g + 8, "9: position after the save")
	run(10 * TICK);
	inj_cmds.delete();
	do_load(0);
	foreach (inj_cmds[i]) $display("9: command %h", inj_cmds[i]);
	`CHECK(inj_cmds.size() == 3, "9: three commands")
	`CHECK(m_start == 5, "9: loop start")
	$display("9: Main at %0d, state %0d", m_lba, m_state);
	`CHECK(m_state == ST_PLAY && m_lba >= g && m_lba <= g + 8, "9: position")
	run(40 * TICK);
	`CHECK(m_state == ST_PLAY && m_lba >= 5 && m_lba <= 41, "9: still in the loop")
	`CHECK(stats == 2, "9: no status")

	//------------------------------------------------------------------ 10
	$display("--- 10: PAUSE, then SAPEP alone goes on, save and load");
	stats = 0;
	core_cmd({88'd0, 8'hDA});                                          // pause the loop of test 9
	wait (stats == 1);
	core_cmd({48'd0, 8'd60, 8'd0, 8'd0, 8'd0, 8'h03, 8'hD9});          // play on to lba 60
	wait (stats == 2);
	run(3 * TICK);
	g = m_lba;
	do_save(1);
	$display("10: Main at %0d (was %0d)", m_lba, g);
	`CHECK(m_state == ST_PLAY && m_lba >= g - 3 && m_lba <= g + 8, "10: position after the save")
	run(5 * TICK);
	do_load(1);
	$display("10: Main at %0d after the load", m_lba);
	`CHECK(m_state == ST_PLAY && m_lba >= g - 3 && m_lba <= g + 8, "10: position after the load")
	`CHECK(stats == 2, "10: statuses")

	//------------------------------------------------------------------ 11
	$display("--- 11: CD audio with interrupt, then READ SUBQ: no status at the end");
	got.delete(); stats = 0;
	core_cmd({48'd0, 8'd10, 8'd0, 8'd0, 8'd0, 8'h00, 8'hD8});          // SAPSP lba 10, silent
	wait (stats == 1);
	core_cmd({48'd0, 8'd50, 8'd0, 8'd0, 8'd0, 8'h02, 8'hD9});          // SAPEP lba 50, interrupt
	run(5 * TICK);
	core_cmd({88'd0, 8'hDD});                                          // the game polls the position
	wait (stats == 2);
	run(3 * TICK);
	`CHECK(dut.drv == 2, "11: still playing after the status of READ SUBQ")
	g = m_lba;
	do_save(2);
	`CHECK(m_state == ST_PLAY && m_lba >= g - 3 && m_lba <= g + 8, "11: position after the save")
	do_load(2);
	`CHECK(m_state == ST_PLAY && m_lba >= g - 3 && m_lba <= g + 8, "11: position after the load")
	`CHECK(!m_int, "11: no interrupt pending in Main")
	wait (m_state == ST_IDLE);
	run(3 * TICK);
	`CHECK(stats == 2, "11: no status at the end")

	//------------------------------------------------------------------ 6
	$display("--- 6: empty slot, state kept");
	got.delete(); stats = 0;
	ac_mode <= 1;   // other slot positions
	do_load(2);
	`CHECK(last_info == 16, "6: empty")
	ac_mode <= 0;

	$display("=== %0d errors", errors);
	if (errors) $fatal(1, "ss_cd test failed");
	$finish;
end

initial begin
	#2000000000;
	$fatal(1, "timeout");
end

endmodule
