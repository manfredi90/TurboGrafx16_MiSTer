//============================================================================
//  Savestates of CD games.
//
//  The CD drive is emulated by Main_MiSTer, so two things are done here:
//
//  - Storage: the states go in the game's save file (VD 0, the .sav Main
//    mounts for every CD), after the backup RAM and the MB128 area, not in
//    .ss files. The savestate engine writes the state to a DDR3 buffer and
//    this module copies it to the file, and back.
//
//  - Drive: what the drive is doing is followed from the commands, sectors,
//    statuses and subcode that go between the core and Main (bus registers
//    80..85). After a load the drive is reset and given the commands that
//    put it back: the read goes on from the sector being read (its bytes
//    already taken by the CPU are dropped), CD audio restarts from the last
//    subcode position, a command still waiting for its status is sent again.
//    Statuses of these commands the CPU does not wait for are dropped. The
//    resume is not exact: audio restarts and data comes after a short pause.
//
//  Slot n starts at block SLOT_LBA0 + n * stride of the save file; the stride
//  is larger with the Arcade Card, whose 2 MB of RAM go in the state too.
//============================================================================

module ss_cd #(parameter [27:0] GAP = 28'd2147000, parameter [27:0] REFILL = 28'd85900000)
(
	input             clk,
	input             reset,

	input             cd_mode,
	input             ac_mode,

	// requests
	input             save,
	input             load,
	input       [1:0] slot,
	output            busy,
	output reg        info_req,
	output reg  [7:0] info,

	// savestate engine
	output reg        eng_save,
	output reg        eng_load,
	input             eng_busy,
	input             eng_load_done,
	input             eng_restore,
	output reg        hold,           // keep the core frozen
	input             paused,         // the core is frozen
	input             core_run,       // the core runs, no freeze requested
	output reg        fifo_clr,

	// savestate bus: drive state, registers 80..85
	input      [63:0] bus_din,
	input       [9:0] bus_adr,
	input             bus_wren,
	input             bus_rst,
	output     [63:0] bus_dout,

	// core to Main
	input      [95:0] comm,
	input             comm_ev,        // command sent (pulse)
	input             dataout_ev,     // MODE SELECT data sent (pulse)
	input             reset_ev,       // drive reset (pulse)
	input             msg_ev,         // any message of the core to Main (pulse)
	output reg        block_out,      // messages of the core to Main are not sent
	output reg        inj_req,        // send inj_data to Main instead (pulse)
	output reg[111:0] inj_data,

	// Main to core
	input             stat_ev,        // status (pulse)
	input      [15:0] stat_in,
	input             dout_ev,        // data request of MODE SELECT (pulse)
	output reg        stat_get,
	output reg [15:0] stat_out,
	output reg        dout_req,

	// packets from Main
	input             pkt_hdr,        // header of a packet (pulse)
	input       [1:0] pkt_ch,         // 1: data, 2: CD audio, 3: subcode
	input      [14:0] pkt_len,
	input             byte_wr,        // a byte of the packet goes to the core (pulse)
	input      [14:0] byte_idx,
	input       [7:0] byte_val,
	output            drop,           // do not give it to the core
	input             scsi_rd,        // the SCSI controller reads its FIFO (rising edge)
	input             scsi_reset,     // the CPU resets the SCSI controller: its FIFO is emptied

	// DDR3 buffer, through ss_ddram
	output reg        ddr_owner,
	output reg [25:0] ddr_adr,
	output reg [63:0] ddr_din,
	output reg        ddr_rnw,
	output reg        ddr_req,
	input             ddr_done,
	input      [63:0] ddr_dout,

	// save file (VD 0)
	input             mounting,       // the save file is mounted (with the BIOS download)
	input      [63:0] img_size,
	input             hps_wr,         // write request given to hps_io, from here or the backup logic
	input      [31:0] hps_lba,
	input       [5:0] hps_blks,
	output reg        bk_force,       // save the backup RAM: creates the file
	input             bk_busy,
	output reg        sd_act,
	output reg [31:0] sd_lba,
	output reg  [5:0] sd_blk_cnt,
	output reg        sd_rd,
	output reg        sd_wr,
	input             sd_ack,
	input      [12:0] sd_buff_addr,
	input      [15:0] sd_buff_dout,
	output     [15:0] sd_buff_din,
	input             sd_buff_wr
);

localparam [25:0] BUF_ADR   = 26'h3900000;  // 0x3E400000 in DDR3, 32-bit words
localparam [31:0] SLOT_LBA0 = 32'h200;      // 256 KB into the save file
localparam [31:0] STRIDE    = 32'h500;      // 640 KB
localparam [31:0] STRIDE_AC = 32'h1500;     // 2.6 MB
localparam [31:0] SIZE_CD   = 32'd148800;   // STATESIZE_CD of savestates.vhd
localparam [31:0] SIZE_AC   = 32'd673088;   // STATESIZE_AC
localparam [31:0] LBAS_CD   = ((SIZE_CD + 2) * 4 + 511) / 512;
localparam [31:0] LBAS_AC   = ((SIZE_AC + 2) * 4 + 511) / 512;

localparam [7:0] I_SAVED = 14, I_LOADED = 15, I_EMPTY = 16, I_FAILED = 17;

localparam [1:0] DRV_IDLE = 0, DRV_READ = 1, DRV_PLAY = 2, DRV_PAUSE = 3;

// GAP: 50 ms between commands to Main, REFILL: 2 s for the sector being read to come again

localparam [7:0] MODE_LOOP = 8'h01, MODE_INT = 8'h02;

//----------------------------------------------------------------------------
// drive state

reg  [95:0] last_cmd;
reg         awaiting;     // its status has not reached the core yet
reg         data_rcvd;    // a data packet came for it
reg         dout_got;     // MODE SELECT: data request given to the core
reg         dout_sent;    // MODE SELECT: data sent by the core
reg   [1:0] drv;
reg  [20:0] rd_lba;       // next sector of READ
reg   [8:0] rd_cnt;       // sectors still to come
reg  [95:0] sapsp, sapep;
reg         sapep_valid;
reg         paused_da;    // PAUSE command after playing
reg  [18:0] sub_lba;      // position from the subcode
reg         sub_valid;
reg  [11:0] fifo_cnt;     // bytes in the SCSI FIFO
reg  [11:0] pkt_pos;      // bytes of the last data packet that came
reg  [11:0] pkt_size;
reg         pkt_rd;       // it was a sector of READ

// copy of the state, kept while the engine reads it
reg  [63:0] s80, s81, s82, s83, s84, s85;
wire [63:0] l80 = last_cmd[63:0];
wire [63:0] l81 = {drv, rd_cnt, rd_lba, last_cmd[95:64]};
wire [63:0] l82 = sapsp[63:0];
wire [63:0] l83 = {sapep[95:64], sapsp[95:64]};
wire [63:0] l84 = sapep[63:0];
wire [63:0] l85 = {1'b0, paused_da, dout_sent, dout_got, pkt_rd, pkt_size, pkt_pos, fifo_cnt,
                   sapep_valid, data_rcvd, awaiting, sub_valid, sub_lba};

always @(posedge clk) if (bus_adr < 10'd80 || bus_adr > 10'd85) {s80, s81, s82, s83, s84, s85} <= {l80, l81, l82, l83, l84, l85};

wire [63:0] i80, i81, i82, i83, i84, i85;
wire [63:0] d80, d81, d82, d83, d84, d85;
eReg_SavestateV #(10'd80, 64'd0) reg80 (clk, bus_din, bus_adr, bus_wren, bus_rst, d80, s80, i80);
eReg_SavestateV #(10'd81, 64'd0) reg81 (clk, bus_din, bus_adr, bus_wren, bus_rst, d81, s81, i81);
eReg_SavestateV #(10'd82, 64'd0) reg82 (clk, bus_din, bus_adr, bus_wren, bus_rst, d82, s82, i82);
eReg_SavestateV #(10'd83, 64'd0) reg83 (clk, bus_din, bus_adr, bus_wren, bus_rst, d83, s83, i83);
eReg_SavestateV #(10'd84, 64'd0) reg84 (clk, bus_din, bus_adr, bus_wren, bus_rst, d84, s84, i84);
eReg_SavestateV #(10'd85, 64'd0) reg85 (clk, bus_din, bus_adr, bus_wren, bus_rst, d85, s85, i85);
assign bus_dout = d80 | d81 | d82 | d83 | d84 | d85;

// subcode Q is bit 6 of subcode bytes 2..97
reg  [95:0] q;
reg         q_done;
wire  [7:0] q_m = q[39:32], q_s = q[31:24], q_f = q[23:16];
wire [19:0] q_lba = q_m[7:4] * 17'd45000 + q_m[3:0] * 13'd4500 + q_s[7:4] * 10'd750 + q_s[3:0] * 7'd75
                  + q_f[7:4] * 4'd10 + q_f[3:0];

// bytes to drop at the start of the next data packet
reg  [11:0] drop_k, drop_cur;
reg         drop_arm, drop_all;
reg   [2:0] swallow;
reg         stat_pend, dout_pend;
reg         refill_arm, refill_pkt, refill_done;

assign drop = drop_all | (pkt_ch == 2'd1 && byte_idx < drop_cur);

// requests from the sequencer
reg         set_drop, set_drop_all, clr_drop_all, set_swallow, set_refill, set_skip;
reg         skip_adv;
reg  [11:0] set_drop_k;
reg         res_partial;  // a sector of READ was not all read by the CPU
reg         res_part_nr;  // the same for the answer of another command
reg  [11:0] res_k;

task automatic cmd_apply(input [95:0] c);
	last_cmd  <= c;
	awaiting  <= 1;
	data_rcvd <= 0;
	dout_got  <= 0;
	dout_sent <= 0;
	case (c[7:0])
		8'h08: begin
			drv    <= DRV_READ;
			rd_lba <= {c[12:8], c[23:16], c[31:24]};
			rd_cnt <= c[39:32] ? {1'b0, c[39:32]} : 9'd256;
		end
		8'hD8: begin
			drv         <= c[15:8] ? DRV_PLAY : DRV_PAUSE;
			sapsp       <= c;
			sapep_valid <= 0;
			sub_valid   <= 0;
			paused_da   <= 0;
		end
		8'hD9: begin
			drv         <= c[15:8] ? DRV_PLAY : DRV_IDLE;
			sapep       <= c;
			sapep_valid <= 1;
			sub_valid   <= 0;
		end
		8'hDA: begin
			if (drv == DRV_PLAY) paused_da <= 1;
			drv <= DRV_PAUSE;
		end
		default:;
	endcase
endtask

always @(posedge clk) begin
	reg old_rd;

	stat_get <= 0;
	dout_req <= 0;
	q_done   <= 0;

	// commands of the core; the ones sent after a load are not followed, they
	// put the drive back in the state these registers already have
	if (comm_ev) cmd_apply(comm);

	if (dataout_ev) dout_sent <= 1;

	if (reset_ev) begin
		drv         <= DRV_IDLE;
		awaiting    <= 0;
		rd_cnt      <= 0;
		sapep_valid <= 0;
		sub_valid   <= 0;
		paused_da   <= 0;
	end

	// statuses: dropped, or given to the core while it runs
	if (stat_ev && !drop_all) begin
		if (swallow) swallow <= swallow - 1'd1;
		else begin
			stat_pend <= 1;
			stat_out  <= stat_in;
		end
		if (drv == DRV_PLAY && sapep_valid && sapep[15:8] == MODE_INT) drv <= DRV_IDLE;
	end
	if (dout_ev && !drop_all) dout_pend <= 1;

	if (stat_pend && core_run) begin
		stat_get  <= 1;
		stat_pend <= 0;
		awaiting  <= 0;
	end
	if (dout_pend && core_run) begin
		dout_req  <= 1;
		dout_pend <= 0;
		dout_got  <= 1;
	end

	// data packets
	if (pkt_hdr && pkt_ch == 2'd1 && !drop_all) begin
		pkt_pos  <= 0;
		pkt_size <= pkt_len[11:0];
		drop_cur <= drop_arm ? drop_k : 12'd0;
		drop_arm <= 0;
		pkt_rd   <= 0;
		skip_adv <= 0;
		if (skip_adv) pkt_rd <= 1;  // the sector read again after a load
		else if (pkt_len == 15'd2048 && drv == DRV_READ && rd_cnt) begin
			pkt_rd <= 1;
			rd_lba <= rd_lba + 1'd1;
			rd_cnt <= rd_cnt - 1'd1;
			if (rd_cnt == 1) drv <= DRV_IDLE;
		end
		else if (awaiting) data_rcvd <= 1;
		if (refill_arm) begin
			refill_arm <= 0;
			refill_pkt <= 1;
		end
	end

	old_rd <= scsi_rd;
	if (byte_wr && pkt_ch == 2'd1 && !drop_all) begin
		pkt_pos <= pkt_pos + 1'd1;
		if (refill_pkt && pkt_pos + 1'd1 >= pkt_size) begin
			refill_pkt  <= 0;
			refill_done <= 1;
		end
	end
	fifo_cnt <= fifo_cnt + (byte_wr && pkt_ch == 2'd1 && !drop) - (scsi_rd && !old_rd);
	if (scsi_reset) begin
		fifo_cnt <= 0;
		pkt_rd   <= 0;
		pkt_size <= 0;
	end

	// subcode
	if (pkt_hdr && pkt_ch == 2'd3) q <= 0;
	if (byte_wr && pkt_ch == 2'd3 && byte_idx >= 2 && byte_idx < 98) begin
		q <= {q[94:0], byte_val[6]};
		if (byte_idx == 97) q_done <= 1;
	end
	// not while the drive is put back: it goes through other positions
	if (q_done && q[91:88] == 4'd1 && (drv == DRV_PLAY || (drv == DRV_PAUSE && paused_da)) && !block_out) begin
		sub_lba   <= (q_lba < 150) ? 19'd0 : q_lba[18:0] - 19'd150;
		sub_valid <= 1;
	end

	if (eng_restore) begin
		last_cmd    <= {i81[31:0], i80};
		rd_lba      <= i81[52:32];
		rd_cnt      <= i81[61:53];
		drv         <= i81[63:62];
		sapsp       <= {i83[31:0], i82};
		sapep       <= {i83[63:32], i84};
		sub_lba     <= i85[18:0];
		sub_valid   <= i85[19];
		awaiting    <= i85[20];
		data_rcvd   <= i85[21];
		sapep_valid <= i85[22];
		fifo_cnt    <= i85[34:23];
		pkt_pos     <= i85[46:35];
		pkt_size    <= i85[58:47];
		pkt_rd      <= i85[59];
		dout_got    <= i85[60];
		dout_sent   <= i85[61];
		paused_da   <= i85[62];
	end

	// from the sequencer
	if (fifo_clr) begin
		res_partial <= pkt_rd && (fifo_cnt || pkt_pos != pkt_size);
		res_part_nr <= !pkt_rd && pkt_size && (fifo_cnt || pkt_pos != pkt_size);
		res_k       <= pkt_pos - fifo_cnt;
		fifo_cnt    <= 0;
	end
	if (set_swallow) swallow <= swallow + 1'd1;
	if (set_drop) begin
		drop_k   <= set_drop_k;
		drop_arm <= 1;
	end
	if (set_skip) skip_adv <= 1;
	if (set_refill) begin
		refill_arm  <= 1;
		refill_pkt  <= 0;
		refill_done <= 0;
	end
	if (set_drop_all) drop_all <= 1;
	if (clr_drop_all) begin
		drop_all   <= 0;
		drop_cur   <= 0;
		drop_arm   <= 0;
		swallow    <= 0;
		stat_pend  <= 0;
		dout_pend  <= 0;
		refill_arm <= 0;
		refill_pkt <= 0;
		skip_adv   <= 0;
	end

	if (reset) begin
		drv         <= DRV_IDLE;
		awaiting    <= 0;
		sapep_valid <= 0;
		sub_valid   <= 0;
		paused_da   <= 0;
		stat_pend   <= 0;
		dout_pend   <= 0;
		swallow     <= 0;
		drop_arm    <= 0;
		drop_cur    <= 0;
		drop_all    <= 0;
		fifo_cnt    <= 0;
		pkt_rd      <= 0;
		refill_arm  <= 0;
		refill_pkt  <= 0;
		skip_adv    <= 0;
	end
end

//----------------------------------------------------------------------------
// copy buffer: 16 KB, 32 blocks of the save file

reg  [12:0] buf_a;
reg  [15:0] buf_d;
reg         buf_we;
wire [15:0] buf_q;
reg         zero_fill;
wire [15:0] buf_qb;

dpram #(13,16) copybuf
(
	.clock(clk),
	.address_a(buf_a),
	.data_a(buf_d),
	.wren_a(buf_we),
	.q_a(buf_q),

	.address_b(sd_buff_addr),
	.data_b(sd_buff_dout),
	.wren_b(sd_act & sd_buff_wr & sd_ack),
	.q_b(buf_qb)
);

assign sd_buff_din = zero_fill ? 16'h0000 : buf_qb;

// size of the save file in blocks: from the mount, then from the writes
// (Main writes a block only if it is not past the end of the file)
reg  [31:0] sav_lbas;
always @(posedge clk) begin
	reg        old_ack, wr;
	reg [31:0] wr_lba, wr_end;

	old_ack <= sd_ack;
	if (~old_ack & sd_ack) begin
		wr     <= hps_wr;
		wr_lba <= hps_lba;
		wr_end <= hps_lba + hps_blks + 1'd1;
	end
	if (old_ack & ~sd_ack & wr && wr_lba <= sav_lbas && wr_end > sav_lbas) sav_lbas <= wr_end;
	if (mounting) sav_lbas <= img_size[40:9] + |img_size[8:0];
end

//----------------------------------------------------------------------------
// sequencer

typedef enum logic [4:0] {
	S_IDLE,
	S_SV_ENG, S_SV_ENGWAIT, S_SV_STOP, S_SV_RESYNC, S_SV_FILE, S_SV_BK, S_SV_BKWAIT, S_SV_PAD, S_SV_FILL, S_SV_NEXT,
	S_LD_HDR, S_LD_CHECK, S_LD_FREEZE, S_LD_COPY, S_LD_NEXT, S_LD_ENG, S_LD_ENGWAIT,
	S_LD_STEP, S_LD_SETTLE,
	S_SD_WAIT, S_FAIL, S_DONE
} state_t;

state_t     st, st_ret;
reg  [31:0] slot_lba;
reg  [31:0] total_lbas;
reg  [31:0] lba_n;       // blocks done
reg  [10:0] q_n;         // 64-bit words of the buffer done
reg   [2:0] c;
reg  [27:0] wait_cnt;
reg  [27:0] since_inj;   // time since the last command to Main
reg   [2:0] step;
reg         load_ok;
reg         saving;
reg         old_ack;
reg  [15:0] size_lo;

assign busy = (st != S_IDLE);

wire [31:0] stride = ac_mode ? STRIDE_AC : STRIDE;
wire [31:0] size_rd = {buf_q, size_lo};

// commands for the drive after a load
wire  [7:0] play_mode = sapep_valid ? sapep[15:8] : sapsp[15:8];
wire  [7:0] sp_mode   = (drv == DRV_PAUSE) ? 8'h00 : sapsp[15:8];
wire [95:0] sapsp_pos = {48'd0, sub_lba[7:0], sub_lba[15:8], 5'd0, sub_lba[18:16], 8'h00, sp_mode, 8'hD8};
wire [95:0] sapsp_org = {sapsp[95:16], sp_mode, 8'hD8};
wire        use_pos   = sub_valid && (drv == DRV_PAUSE ? paused_da : play_mode != MODE_LOOP);
// a loop restarts from the position of SAPSP: that goes to the loop start, then a read
// of one sector of the audio track moves the head to where the music was
wire        loop_pos  = sub_valid && drv == DRV_PLAY && play_mode == MODE_LOOP;
wire [95:0] read_pos  = {56'd0, 8'd1, sub_lba[7:0], sub_lba[15:8], 5'd0, sub_lba[18:16], 8'h08};
wire [95:0] sapep_end = {16'd0, 8'h80, 48'd0, 8'h99, MODE_LOOP, 8'hD9};   // up to the end of the disc
wire [20:0] rl        = res_partial ? rd_lba - 1'd1 : rd_lba;
wire  [8:0] rc        = res_partial ? rd_cnt + 1'd1 : rd_cnt;
wire [20:0] rl_last   = rd_lba - 1'd1;
wire        fast      = 1'b1;        // no seek time when resuming

always @(posedge clk) begin
	eng_save     <= 0;
	eng_load     <= 0;
	info_req     <= 0;
	fifo_clr     <= 0;
	bk_force     <= 0;
	inj_req      <= 0;
	ddr_req      <= 0;
	buf_we       <= 0;
	set_swallow  <= 0;
	set_drop     <= 0;
	set_drop_all <= 0;
	clr_drop_all <= 0;
	set_refill   <= 0;
	set_skip     <= 0;

	old_ack <= sd_ack;
	if (~old_ack & sd_ack) {sd_rd, sd_wr} <= 0;

	// Main sees a message when the toggle bit changes: two too close, and both are lost
	if (~&since_inj) since_inj <= since_inj + 1'd1;
	if (msg_ev) since_inj <= 0;
	wait_cnt <= wait_cnt + 1'd1;

	case (st)
		S_IDLE: begin
			hold       <= 0;
			block_out  <= 0;
			sd_act     <= 0;
			ddr_owner  <= 0;
			zero_fill  <= 0;
			slot_lba   <= SLOT_LBA0 + slot * stride;
			total_lbas <= ac_mode ? LBAS_AC : LBAS_CD;
			wait_cnt   <= 0;
			if (cd_mode && !reset) begin
				if (save) st <= S_SV_ENG;
				else if (load) st <= S_LD_HDR;
			end
		end

		//------------------------------------------------------------------ save
		S_SV_ENG: begin
			// the core stays frozen until the state is in the file
			hold     <= 1;
			eng_save <= 1;
			wait_cnt <= 0;
			st       <= S_SV_ENGWAIT;
		end

		S_SV_ENGWAIT: if (wait_cnt > 4 && !eng_busy) st <= S_SV_STOP;

		// the copy takes seconds: the drive must not go on meanwhile (CD audio would be
		// ahead of the game), it is stopped and then put back as after a load
		S_SV_STOP: if (since_inj >= GAP) begin
			saving       <= 1;
			block_out    <= 1;
			set_drop_all <= 1;
			inj_data     <= {16'h00FF, 96'd0};
			inj_req      <= 1;
			since_inj    <= 0;
			st           <= S_SV_FILE;
		end

		S_SV_RESYNC: begin
			sd_act       <= 0;
			ddr_owner    <= 0;
			zero_fill    <= 0;
			fifo_clr     <= 1;
			clr_drop_all <= 1;
			step         <= 0;
			st           <= S_LD_STEP;
		end

		S_SV_FILE: st <= sav_lbas ? S_SV_PAD : S_SV_BK;

		// the file must exist: the backup RAM save creates it
		S_SV_BK: if (!bk_busy) begin
			bk_force <= 1;
			wait_cnt <= 0;
			st       <= S_SV_BKWAIT;
		end

		S_SV_BKWAIT: if (wait_cnt > 8 && !bk_busy) st <= sav_lbas ? S_SV_PAD : S_FAIL;

		// zeros up to the slot: a file can only grow at its end
		S_SV_PAD: if (!bk_busy) begin
			if (sav_lbas >= slot_lba) begin
				zero_fill <= 0;
				lba_n     <= 0;
				q_n       <= 0;
				c         <= 0;
				ddr_owner <= 1;
				ddr_rnw   <= 1;
				ddr_adr   <= BUF_ADR;
				st        <= S_SV_FILL;
			end
			else begin
				zero_fill  <= 1;
				sd_act     <= 1;
				sd_lba     <= sav_lbas;
				sd_blk_cnt <= (slot_lba - sav_lbas >= 32) ? 6'd31 : slot_lba[5:0] - sav_lbas[5:0] - 1'd1;
				sd_wr      <= 1;
				st_ret     <= S_SV_PAD;
				st         <= S_SD_WAIT;
			end
		end

		// 16 KB from DDR3 to the buffer, then to the file
		S_SV_FILL: begin
			c <= c + 1'd1;
			case (c)
				0: ddr_req <= 1;
				1: if (!ddr_done) c <= c;
				2,3,4,5: begin
						buf_a  <= {q_n, c[1:0] - 2'd2};
						buf_d  <= ddr_dout[{c[1:0] - 2'd2, 4'd0} +: 16];
						buf_we <= 1;
						if (c == 5) begin
							c       <= 0;
							q_n     <= q_n + 1'd1;
							ddr_adr <= ddr_adr + 2'd2;
							if (&q_n) begin
								sd_act     <= 1;
								sd_lba     <= slot_lba + lba_n;
								sd_blk_cnt <= 6'd31;
								sd_wr      <= 1;
								st_ret     <= S_SV_NEXT;
								st         <= S_SD_WAIT;
							end
						end
					end
				default:;
			endcase
		end

		S_SV_NEXT: begin
			lba_n <= lba_n + 6'd32;
			if (lba_n + 6'd32 >= total_lbas) begin
				load_ok <= 1;
				st      <= S_SV_RESYNC;
			end
			else st <= S_SV_FILL;
		end

		//------------------------------------------------------------------ load
		// first 16 KB, with the header of the state
		S_LD_HDR: if (!bk_busy) begin
			sd_act     <= 1;
			sd_lba     <= slot_lba;
			sd_blk_cnt <= 6'd31;
			sd_rd      <= 1;
			c          <= 0;
			st_ret     <= S_LD_CHECK;
			st         <= S_SD_WAIT;
		end

		// 32-bit word 1 is the size of the state
		S_LD_CHECK: begin
			c <= c + 1'd1;
			case (c)
				0: buf_a <= 2;
				1: buf_a <= 3;
				2: size_lo <= buf_q;
				3: begin
						if (size_rd == SIZE_CD || (size_rd == SIZE_AC && ac_mode)) begin
							total_lbas <= (size_rd == SIZE_AC) ? LBAS_AC : LBAS_CD;
							hold <= 1;
							st   <= S_LD_FREEZE;
						end
						else begin
							info <= I_EMPTY;
							st   <= S_DONE;
						end
					end
				default:;
			endcase
		end

		// stop the drive and everything it still sends
		S_LD_FREEZE: if (paused && since_inj >= GAP) begin
			block_out    <= 1;
			set_drop_all <= 1;
			inj_data     <= {16'h00FF, 96'd0};
			inj_req      <= 1;
			since_inj    <= 0;
			lba_n        <= 0;
			q_n          <= 0;
			c            <= 0;
			ddr_owner    <= 1;
			ddr_rnw      <= 0;
			ddr_adr      <= BUF_ADR;
			st           <= S_LD_COPY;
		end

		// buffer to DDR3, 64 bits at a time
		S_LD_COPY: begin
			c <= c + 1'd1;
			case (c)
				0: buf_a <= {q_n, 2'd0};
				1: buf_a <= {q_n, 2'd1};
				2: begin buf_a <= {q_n, 2'd2}; ddr_din[15:0]  <= buf_q; end
				3: begin buf_a <= {q_n, 2'd3}; ddr_din[31:16] <= buf_q; end
				4: ddr_din[47:32] <= buf_q;
				5: begin ddr_din[63:48] <= buf_q; ddr_req <= 1; end
				6: if (!ddr_done) c <= c;
				7: begin
						c       <= 0;
						q_n     <= q_n + 1'd1;
						ddr_adr <= ddr_adr + 2'd2;
						if (&q_n) st <= S_LD_NEXT;
					end
			endcase
		end

		S_LD_NEXT: begin
			lba_n <= lba_n + 6'd32;
			if (lba_n + 6'd32 >= total_lbas) st <= S_LD_ENG;
			else begin
				sd_act     <= 1;
				sd_lba     <= slot_lba + lba_n + 6'd32;
				sd_blk_cnt <= 6'd31;
				sd_rd      <= 1;
				st_ret     <= S_LD_COPY;
				st         <= S_SD_WAIT;
			end
		end

		S_LD_ENG: begin
			sd_act    <= 0;
			ddr_owner <= 0;
			eng_load  <= 1;
			wait_cnt  <= 0;
			st        <= S_LD_ENGWAIT;
		end

		// if the engine refuses the state nothing was changed, and the same
		// commands put the drive back as it was before the load
		S_LD_ENGWAIT: begin
			if (eng_load_done || (wait_cnt > 4 && !eng_busy)) begin
				load_ok      <= eng_load_done;
				fifo_clr     <= 1;
				clr_drop_all <= 1;
				step         <= 0;
				st           <= S_LD_STEP;
			end
		end

		S_LD_STEP: if (since_inj >= GAP) begin
			step <= step + 1'd1;
			case (step)
				// position of CD audio
				0: if (drv == DRV_PLAY || drv == DRV_PAUSE) begin
						inj_data  <= {fast, 15'd0, use_pos ? sapsp_pos : loop_pos ? {sapsp[95:16], 8'h00, 8'hD8} : sapsp_org};
						inj_req   <= 1;
						since_inj <= 0;
						if (!(awaiting && last_cmd[7:0] == 8'hD8)) set_swallow <= 1;
					end
				1: if (loop_pos) begin
						inj_data    <= {fast, 15'd0, read_pos};
						inj_req     <= 1;
						since_inj   <= 0;
						set_swallow <= 1;
					end
				// end of CD audio
				2: if ((drv == DRV_PLAY && sapep_valid) || (awaiting && last_cmd[7:0] == 8'hD9) || loop_pos) begin
						inj_data  <= {fast, 15'd0, sapep_valid ? sapep : sapep_end};
						inj_req   <= 1;
						since_inj <= 0;
						if (play_mode != MODE_INT && !(awaiting && last_cmd[7:0] == 8'hD9)) set_swallow <= 1;
					end
				// sectors
				3: if (last_cmd[7:0] == 8'h08 && (drv == DRV_READ || res_partial || awaiting)) begin
						if (!rd_cnt && !res_partial) begin
							// all sectors were sent, not the status: the last one again, unseen
							inj_data   <= {fast, 15'd0, last_cmd[95:40], 8'd1, rl_last[7:0], rl_last[15:8], 3'd0, rl_last[20:16], 8'h08};
							set_drop_k <= 12'd2048;
							set_skip   <= 1;
						end
						else begin
							inj_data   <= {fast, 15'd0, last_cmd[95:40], rc[7:0], rl[7:0], rl[15:8], 3'd0, rl[20:16], 8'h08};
							set_drop_k <= res_partial ? res_k : 12'd0;
							set_skip   <= res_partial;
							set_refill <= 1;
						end
						set_drop  <= 1;
						inj_req   <= 1;
						since_inj <= 0;
						if (!awaiting) set_swallow <= 1;
					end
				// any other command waiting for its status, or whose answer was not all read
				4: if (res_part_nr || (awaiting && last_cmd[7:0] != 8'h08 && last_cmd[7:0] != 8'hD8 && last_cmd[7:0] != 8'hD9)) begin
						if (last_cmd[7:0] != 8'h15 || !dout_got) begin
							inj_data   <= {fast, 15'd0, last_cmd};
							inj_req    <= 1;
							since_inj  <= 0;
							set_drop_k <= data_rcvd ? res_k : 12'd0;
							set_drop   <= 1;
							set_refill <= res_part_nr;
							if (!awaiting) set_swallow <= 1;
						end
						else if (dout_sent) begin
							// MODE SELECT data was sent: Main answers it with the status
							inj_data  <= {16'h0001, 96'd0};
							inj_req   <= 1;
							since_inj <= 0;
						end
					end
				default: begin
					wait_cnt <= 0;
					st <= S_LD_SETTLE;
				end
			endcase
		end

		// the sector being read must be in the FIFO again before the core runs
		S_LD_SETTLE: if (refill_done || !refill_arm && !refill_pkt || wait_cnt >= REFILL) begin
			info <= !load_ok ? I_FAILED : saving ? I_SAVED : I_LOADED;
			st   <= S_DONE;
		end

		//------------------------------------------------------------------ common
		S_SD_WAIT: if (old_ack & ~sd_ack) begin
			c   <= 0;
			q_n <= 0;
			st  <= st_ret;
		end

		S_FAIL: begin
			info    <= I_FAILED;
			load_ok <= 0;
			st      <= saving ? S_SV_RESYNC : S_DONE;
		end

		S_DONE: begin
			info_req  <= 1;
			hold      <= 0;
			block_out <= 0;
			sd_act    <= 0;
			ddr_owner <= 0;
			zero_fill <= 0;
			saving    <= 0;
			st        <= S_IDLE;
		end

		default: st <= S_IDLE;
	endcase

	if (reset) begin
		st     <= S_IDLE;
		hold   <= 0;
		saving <= 0;
		sd_rd <= 0;
		sd_wr <= 0;
	end
end

endmodule
