//============================================================================
//  Jupiter Ace replica for MiSTer
//  Copyright (C) 2018-2019 Sorgelig
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

assign ADC_BUS  = 'Z;
// the Jupiter II Expansion's serial port: the MiSTer's UART (set up in the OSD's
// UART Mode menu: USB serial adapter, Linux console, modem, ...) or the user port
// (USER_IO 0 = RX, 1 = TX), Options -> Serial Port
wire   uart_rxd, uart_txd;
wire   ser_user = status[28];
assign uart_rxd = ser_user ? USER_IN[0] : UART_RXD;
assign UART_TXD = ser_user ? 1'b1 : uart_txd;
assign USER_OUT = ser_user ? {5'h1F, uart_txd, 1'b1} : '1;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = 0;

assign LED_USER  = ioctl_download;
assign LED_DISK  = {1'b0, tape_playing};
assign LED_POWER = 0;
assign BUTTONS   = 0;
assign VGA_SCALER= 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;
assign HDMI_BORDER = status[27] ? 24'hFFFFFF : 24'h000000;  // Inverse Video: the area around the picture too

wire [1:0] ar = status[9:8];
video_freak video_freak
(
	.*,
	.VGA_DE_IN(VGA_DE),
	.VGA_DE(),

	.ARX((!ar) ? 12'd4 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd3 : 12'd0),
	.CROP_SIZE(0),
	.CROP_OFF(0),
	.SCALE(status[11:10])
);

`include "build_id.v"
parameter CONF_STR = {
	"JupiterACE;UART9600:19200:4800:2400:1200:600:300;",
	"-;",
	"F1,ACE,Load Snapshot;",
	"RE,Save Snapshot;",
	"RL,Save Dictionary;",
	"S0,TAPTZX,Insert Tape;",
	"TG,Eject Tape;",
	"TC,Tape Play/Pause;",
	"TD,Tape Rewind;",
	"-;",
	"S3,FTH,Spool Forth File;",
	"TK,Stop Spool;",
	"-;",
	"S2,TAPTZXACEFTH,Delete;",
	"-;",
	"P1,Options;",
	"P1O6,Tape Auto Play,Off,On;",
	"P1OJ,Tape Auto Rewind,Off,On;",
	"P1O7,Tape Sound,On,Off;",
	"P1OF,Fast Tape,Off,On;",
	"P1OI,New Tape Format,TAP,TZX;",
	"P1-;",
	"P1O89,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O23,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"P1OAB,Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"P1-;",
	"P1O45,CPU Speed,Normal,x2,x4;",
	"P1OMO,Memory,51K,35K,19K,3K,99K;",
	"P1OPQ,Machine,Jupiter ACE,Jupiter II,Jupiter II + Exp;",
	"P1OR,Inverse Video,Off,On;",
	"P1OS,Serial Port,MiSTer UART,User Port;",
	"-;",
	"R0,Reset;",
	"J,Fire;",
	"I,Tape saved,New tape created,Tape full: save discarded,Save failed: bad block,Save failed: run JupiterACE.sh,Snapshot saved,Snapshot: run JupiterACE.sh,Snapshot failed: CPU busy,File deleted,Delete failed: see log,JupiterACE.sh not running,Delete: run JupiterACE.sh,Tape save failed: see log,Snapshot failed: see log,Spool done,Spool done with errors,Spool stopped: line not OK,Spool stopped,Dictionary saved,Dictionary failed: see log,Memory raised for snapshot,Snapshot failed: too big,Snapshot needs Jupiter II+Exp,Snapshot is for Jupiter ACE/II;",
	"V,v",`BUILD_DATE
};

/////////////////  CLOCKS  ////////////////////////

wire clk_sys;

pll pll
(
	.refclk(CLK_50M),
	.outclk_0(clk_sys)
);

wire [1:0] turbo = status[5:4];
wire       fast_load;  // Fast Tape: CPU and tape run 8x while the tape plays or records

reg ce_pix;
reg ce_cpu;
always @(negedge clk_sys) begin
	reg [3:0] div;

	div <= div + 1'd1;
	ce_pix <= !div[2:0];
	// the T80 needs at least 2 clocks per T-state, so 8x (every 2nd clock) is the top speed
	ce_cpu <= fast_load ? !div[0] :
	          turbo[1]  ? !div[1:0] :   // x4
	          turbo[0]  ? !div[2:0] :   // x2
	                      !div[3:0];    // 3.25 MHz
end

/////////////////  HPS  ///////////////////////////

wire [31:0] status;
wire  [1:0] buttons;

wire [15:0] joya, joyb;
wire [10:0] ps2_key;

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
reg         ioctl_wait = 0;
wire        forced_scandoubler;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(4)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	.forced_scandoubler(forced_scandoubler),

	.ps2_key(ps2_key),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),

	.joystick_0(joya),
	.joystick_1(joyb),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba('{tl_lba, f_lba, del_lba2, sp_lba}),
	.sd_blk_cnt('{6'd0, 6'd0, 6'd0, 6'd0}),
	.sd_rd({sp_rd, del_rd2, f_rd, tl_rd}),
	.sd_wr({2'b00, f_wr, 1'b0}),
	.sd_ack({sp_ack, del_ack2, f_ack, tl_ack}),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{8'h00, f_din, 8'h00, 8'h00}),
	.sd_buff_wr(sd_buff_wr),

	.info_req(tape_msg | snap_msg | del_info_req | poll_info_req | sp_info_req | new_start | mem_raised | ld_msg),
	.info(new_start ? 8'd2 : mem_raised ? 8'd21 : ld_msg ? ld_msg_info : tape_msg ? tape_info : snap_msg ? snap_info : del_info_req ? del_info : poll_info_req ? poll_info : sp_info)
);

// SD slot 0: tape image (S0 option)
// SD slot 1: games/JupiterACE/boot1.vhd, mounted when the core starts:
//            sectors 0-760 snapshots, 761-1017 tape saves, 1018 delete
//            requests. Only one of the three writers uses it at a time.
// SD slot 2: the file picked in "Delete" (S2 option)
// SD slot 3: the file picked in "Spool Forth File" (S3 option)
wire  [3:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba, snap_lba;
wire        sd_wr, sd_ack, snap_wr, snap_ack;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_din, snap_buff_din, sd_buff_dout;
wire        sd_buff_wr;
wire [31:0] f_lba  = snap_busy ? snap_lba : del_busy ? del_lba1 : poll_busy ? poll_lba : sd_lba + 32'd761;
wire        f_wr   = snap_wr | sd_wr | del_wr1;
wire        f_rd   = del_rd1 | poll_rd;
wire  [7:0] f_din  = snap_busy ? snap_buff_din : del_busy ? del_din1 : sd_buff_din;
wire        f_ack;
assign      snap_ack = f_ack;
assign      sd_ack   = f_ack;
wire        tape_info_req, snap_info_req;
wire  [7:0] tape_info, snap_info;

reg [15:0] loader_addr;
reg  [7:0] loader_data;
reg        loader_wr;
reg        loader_en;
reg        loader_reset = 0;

// The .ACE loader. After the image's end marker (ED 00) a snapshot of a 96K RAM
// pack (xAce's extension) carries the other page:
//   "XACE96K" 01 <page in use>, then 4000-FFFF of the other page, packed the same way, ED 00
// The image goes into physical page 0 and that block into physical page 1; when
// loading ends the page in use is set to map onto physical page 0 (see ace.sv).
// The memory is enlarged if the snapshot needs more than is set (its RAMTOP, or
// data above the current memory, or the 96K block).
reg  [2:0] ld_blk;          // 0 the image, 1 a block header, 2 the 96K pack's other page,
                            // 3 done, 4 the Jupiter II Expansion's state
reg  [3:0] ld_sig;
reg        ld_m_a, ld_m_x, ld_m_j;   // the header so far matches ACE-96K, XACE96K, JUPITR2
reg        ld_blk_seen, ld_blk_page, ld_r7;
reg  [2:0] ld_need;          // memory the snapshot needs (rank, see MEMORY)
reg        ld_need_set;      // pulse
reg        pg_set;           // pulse: loading ended, set the 96K page
reg        pg_set_page;
reg        ld_msg;           // pulse: a block for another machine was skipped ...
reg  [7:0] ld_msg_info;      // ... this message
reg        ay_mpage0;        // pulse: memory page 0 (see below)
wire       ld_phys  = (ld_blk == 3'd2);
wire       ld_state = (ld_blk == 3'd4);
wire       ld_image = (ld_blk == 3'd0);   // the image: it holds the CPU registers

// the Expansion's state, in the order of the JUPITR2 block (as snap_save.sv):
// byte st_k goes to space st_sp, page st_pg, address st_addr (see ace.sv)
reg [17:0] st_k;
reg  [2:0] st_sp;
reg  [1:0] st_pg;
reg [15:0] st_addr;
reg [17:0] st_o;
wire [7:0] port_b_out;
always @(*) begin
	st_sp = 3'd5; st_pg = 2'd0; st_addr = 16'd0; st_o = 18'd0;
	if(st_k < 18'd19) ;
	else if(st_k < 18'd1043) begin st_sp = 3'd1; st_pg = {1'b0, ~port_b_out[2]}; st_o = st_k - 18'd19;   st_addr = 16'h2000 + st_o[9:0]; end
	else if(st_k < 18'd2067) begin st_sp = 3'd2; st_pg = {1'b0, ~port_b_out[3]}; st_o = st_k - 18'd1043; st_addr = 16'h2800 + st_o[9:0]; end
	else if(st_k < 18'd3091) begin st_sp = 3'd3; st_pg = 2'd0; st_o = st_k - 18'd2067; st_addr = {6'd0, st_o[9:0]}; end
	else if(st_k < 18'd4115) begin st_sp = 3'd3; st_pg = 2'd1; st_o = st_k - 18'd3091; st_addr = {6'd0, st_o[9:0]}; end
	else begin st_sp = 3'd4; st_o = st_k - 18'd4115; st_pg = st_o[16:15]; st_addr = {1'b1, st_o[14:0]}; end
end
wire       ay_ld      = ld_state & loader_wr & (st_k < 18'd17);
reg        xs_swap_set;      // pulse: after the registers, the pages shown are known
reg        xs_sswap, xs_cswap;

function [7:0] sig_a(input [2:0] i);     // ACE-96K (Jupiter-IIb, xAce from now)
	case(i)
		0: sig_a = "A"; 1: sig_a = "C"; 2: sig_a = "E"; 3: sig_a = "-";
		4: sig_a = "9"; 5: sig_a = "6"; default: sig_a = "K";
	endcase
endfunction
function [7:0] sig_x(input [2:0] i);     // XACE96K (xAce until now)
	case(i)
		0: sig_x = "X"; 1: sig_x = "A"; 2: sig_x = "C"; 3: sig_x = "E";
		4: sig_x = "9"; 5: sig_x = "6"; default: sig_x = "K";
	endcase
endfunction
function [7:0] sig_j(input [2:0] i);     // JUPITR2
	case(i)
		0: sig_j = "J"; 1: sig_j = "U"; 2: sig_j = "P"; 3: sig_j = "I";
		4: sig_j = "T"; 5: sig_j = "R"; default: sig_j = "2";
	endcase
endfunction

always @(posedge clk_sys) begin
	reg [7:0] cnt = 0;
	reg [1:0] status = 0;
	reg       old_download;
	integer   timeout = 0;

	old_download <= ioctl_download;
	ld_need_set  <= 0;
	pg_set       <= 0;
	ld_msg       <= 0;
	ay_mpage0    <= 0;
	xs_swap_set  <= 0;

	loader_reset <= 0;
	if(~old_download && ioctl_download && ioctl_index[5:0] == 1) begin
		loader_addr <= 'h2000;
		status <= 0;
		loader_reset <=1;
		// hold the CPU from now on, not from the first byte: while the file is
		// being read the CPU would otherwise restart, and with the Expansion its
		// start-up code changes the pages shown before the image is loaded
		loader_en <= 1;
		ioctl_wait <= 1;
		timeout <= 3000000;
		cnt <= 0;
		ld_blk      <= 0;
		ld_blk_seen <= 0;
		ld_r7       <= 0;
		xs_swap_set <= 1;            // the image goes into page 1 of each pair
		xs_sswap    <= 0;
		xs_cswap    <= 0;
	end

	loader_wr <= 0;
	if(loader_wr) begin
		// (the Expansion's state has its own addresses: the image's count stops)
		if(!ld_state) loader_addr <= loader_addr + 1'd1;
		if(ld_blk == 3'd0) begin
			// what the snapshot needs: bit 7 of R, RAMTOP, and memory above the current size
			if(loader_addr == 16'h2140) ld_r7 <= loader_data[7];
			if(loader_addr == 16'h3C19) begin
				ld_need_set <= 1;
				ld_need     <= (loader_data == 8'h00) ? 3'd3 : (loader_data <= 8'h40) ? 3'd0 :
				               (loader_data <= 8'h80) ? 3'd1 : (loader_data <= 8'hC0) ? 3'd2 : 3'd3;
				// the Expansion: a snapshot using RAM above C000 needs memory page 0
				// there, not the Expansion ROM (as Jupiter-IIb does)
				if(mach == 2'd2 && (loader_data == 8'h00 || loader_data > 8'hC0)) ay_mpage0 <= 1;
			end
			if(loader_addr[15:14] != 2'b00) begin
				ld_need_set <= 1;
				ld_need     <= {1'b0, loader_addr[15:14]};   // 4000: 19K, 8000: 35K, C000: 51K
			end
		end
		if(ld_phys) begin ld_need_set <= 1; ld_need <= 3'd4; end
		if(ld_state) begin
			st_k <= st_k + 1'd1;
			// the registers are in: the pages shown are now known
			if(st_k == 18'd18) begin
				xs_swap_set <= 1;
				xs_sswap    <= port_b_out[2] ^ 1'b1;
				xs_cswap    <= port_b_out[3] ^ 1'b1;
			end
		end
	end

	if(ioctl_wr && ioctl_index[5:0] == 1) begin
		loader_en <= 1;
		if(ld_blk == 3'd1) begin
			// a block after the image: "ACE-96K" / "XACE96K" 01 <page>, or "JUPITR2" 01
			if(ld_sig < 4'd7) begin
				if(ioctl_dout != sig_a(ld_sig[2:0])) ld_m_a <= 0;
				if(ioctl_dout != sig_x(ld_sig[2:0])) ld_m_x <= 0;
				if(ioctl_dout != sig_j(ld_sig[2:0])) ld_m_j <= 0;
				ld_sig <= ld_sig + 1'd1;
			end
			else if(ld_sig == 4'd7) begin
				if(ioctl_dout != 8'h01 || !(ld_m_a | ld_m_x | ld_m_j)) ld_blk <= 3;
				else if(ld_m_j) begin
					if(mach == 2'd2) begin
						ld_blk <= 4;
						st_k   <= 0;
						status <= 0;
					end
					else begin
						ld_blk <= 3;
						ld_msg <= 1; ld_msg_info <= 8'd23;   // needs the Jupiter II + Expansion
					end
				end
				else if(mach == 2'd2) begin
					ld_blk <= 3;
					ld_msg <= 1; ld_msg_info <= 8'd24;       // a 96K pack: not with the Expansion
				end
				else ld_sig <= 4'd8;
			end
			else begin
				if(ioctl_dout[7:1]) ld_blk <= 3;
				else begin
					ld_blk_page <= ioctl_dout[0];
					ld_blk_seen <= 1;
					ld_blk      <= 2;
					loader_addr <= 16'h4000;
					status      <= 0;
				end
			end
		end
		else if(ld_blk != 3'd3) case(status)
			0: if(ioctl_dout == 'hED) status <= 1;
				else begin
					loader_wr <= 1;
					loader_data <= ioctl_dout;
				end
			1: begin
					cnt <= ioctl_dout;
					if(ioctl_dout) status <= 2'd2;
					else begin                          // ED 00: the end of the image or of a block
						status <= 2'd0;
						if(ld_blk == 3'd0) begin
							ld_blk <= 3'd1;
							ld_sig <= 0;
							ld_m_a <= 1; ld_m_x <= 1; ld_m_j <= 1;
						end
						else ld_blk <= 3'd3;
					end
				end
			2: begin
					loader_data <= ioctl_dout;
					ioctl_wait <= 1;
				end
		endcase
	end

	if(ioctl_wait && !loader_wr) begin
		if(cnt) begin
			cnt <= cnt - 1'd1;
			loader_wr <= 1;
		end
		else if(timeout) timeout <= timeout - 1;
		else {status,ioctl_wait} <= 0;
	end

	if(old_download & ~ioctl_download) begin
		loader_en   <= 0;
		pg_set      <= 1;
		pg_set_page <= ld_blk_seen ? ld_blk_page : ld_r7;
	end
	if(reset) ioctl_wait <= 0;
end

/////////////////  MEMORY  ////////////////////////

// Options -> Memory: 51K (default), 35K, 19K, 3K or 99K (Edwin Blink's 96K RAM
// pack: two 48K pages at 4000-FFFF, see ace.sv). Ranks: 0 = 3K, 1 = 19K,
// 2 = 35K, 3 = 51K, 4 = 99K. Changing the option restarts the Ace, so the ROM's
// RAM test finds the new size. A snapshot that needs more memory enlarges it
// until the option is changed again.
wire [2:0] mem_opt  = status[24:22];

// Options -> Machine: 0 Jupiter Ace, 1 Jupiter II, 2 Jupiter II + Expansion (see
// ace.sv); changing it restarts the machine. The Memory option is for the
// Jupiter Ace and the Jupiter II without the Expansion, which has its own.
wire [1:0] mach    = (status[26:25] == 2'd3) ? 2'd0 : status[26:25];
wire       inverse = status[27];
wire [2:0] mem_want = (mem_opt == 3'd1) ? 3'd2 : (mem_opt == 3'd2) ? 3'd1 :
                      (mem_opt == 3'd3) ? 3'd0 : (mem_opt == 3'd4) ? 3'd4 : 3'd3;
reg  [2:0] mem_rank = 3'd3;
reg  [3:0] mem_rst  = 0;     // reset after a change
reg        mem_cold;         // pulse: the memory is new (96K page mapping cleared)
reg        mem_raised;       // pulse: enlarged for a snapshot
always @(posedge clk_sys) begin
	reg [2:0] old_opt = 0;
	reg [1:0] old_mach = 0;

	mem_cold   <= 0;
	mem_raised <= 0;
	old_opt    <= mem_opt;
	old_mach   <= mach;
	if(mem_rst) mem_rst <= mem_rst - 1'd1;

	if(old_opt != mem_opt || old_mach != mach) begin
		mem_rank <= mem_want;
		mem_rst  <= '1;
		mem_cold <= 1;
	end
	else if(ld_need_set && ld_need > mem_rank && mach != 2'd2) begin
		mem_rank   <= ld_need;
		mem_raised <= 1;
	end
end

/////////////////  SNAPSHOT SAVE  /////////////////

wire         snap_hold, snap_held, cpu_halted;
wire [211:0] cpu_reg;
wire         snap_en;
wire  [15:0] snap_addr;
wire   [7:0] snap_data;
wire         snap_busy;

wire ce_run = ce_cpu & ~snap_held;  // tape time stands still while the CPU is stopped

reg old_snap_trig;
reg old_dict_trig;
always @(posedge clk_sys) begin
	old_snap_trig <= status[14];
	old_dict_trig <= status[21];
end
wire snap_other, page;
wire snap_ok_now = ~ioctl_download & ~tape_dl & ~save_busy & ~del_busy;
wire snap_dict;

snap_save snap_save
(
	.clk(clk_sys),
	.reset(reset),
	.trig(~old_snap_trig & status[14] & snap_ok_now),
	.trig_dict(~old_dict_trig & status[21] & snap_ok_now),
	.dict(snap_dict),

	.hold(snap_hold),
	.held(snap_held),
	.halted(cpu_halted),
	.cpu_reg(cpu_reg),
	.mem_rank((mach == 2'd2) ? 3'd3 : mem_rank),   // the Expansion: all of memory, to FFFF
	.pack_page(page),
	.other(snap_other),
	.j2x(mach == 2'd2),
	.ay_regs(ay_regs),
	.port_b(port_b_out),
	.xs_space(snap_xs_space),
	.xs_pg(snap_xs_pg),
	.mem_en(snap_en),
	.mem_addr(snap_addr),
	.mem_data(snap_data),

	.img_mounted(img_mounted[1]),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(snap_lba),
	.sd_wr(snap_wr),
	.sd_ack(snap_ack),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_din(snap_buff_din),

	.busy(snap_busy),
	.sd_hold(poll_busy | save_busy),

	.info_req(snap_info_req),
	.info(snap_info)
);

/////////////////  SCRIPT ANSWERS  ////////////////

// "Tape saved" / "Snapshot saved" are shown once JupiterACE.sh has handled
// the save; the writers' own "saved" messages start the wait instead.
wire tape_msg  = tape_info_req & (tape_info != 8'd1);
wire snap_msg  = snap_info_req & (snap_info != 8'd6);
wire tape_done = tape_info_req & (tape_info == 8'd1);
wire snap_done = snap_info_req & (snap_info == 8'd6);

wire [31:0] poll_lba;
wire        poll_rd, poll_busy;
wire        poll_info_req;
wire  [7:0] poll_info;
wire        save_req;

ack_poll ack_poll
(
	.clk(clk_sys),
	.snap_done(snap_done),
	.snap_dict(snap_dict),
	.tape_done(tape_done),
	.other_busy(snap_busy | save_busy | save_req | del_busy),
	.busy(poll_busy),
	.lba(poll_lba),
	.rd(poll_rd),
	.ack(f_ack),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),
	.info_req(poll_info_req),
	.info(poll_info)
);

/////////////////  DELETE FILE  ///////////////////

wire [31:0] del_lba2, del_lba1;
wire        del_rd2, del_ack2, del_rd1, del_wr1;
wire  [7:0] del_din1;
wire        del_busy;
wire [31:0] del_crc, del_len;
wire        del_done;
wire        del_info_req;
wire  [7:0] del_info;

file_delete file_delete
(
	.clk(clk_sys),

	.img_mounted2(img_mounted[2]),
	.img_mounted1(img_mounted[1]),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.lba2(del_lba2),
	.rd2(del_rd2),
	.ack2(del_ack2),

	.lba1(del_lba1),
	.rd1(del_rd1),
	.wr1(del_wr1),
	.ack1(f_ack),
	.din1(del_din1),

	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),

	.other_busy(snap_busy | save_busy | poll_busy),
	.busy(del_busy),

	.del_crc(del_crc),
	.del_len(del_len),
	.deleted(del_done),

	.info_req(del_info_req),
	.info(del_info)
);

// deleting the inserted tape ejects it
wire [31:0] tape_crc, tape_len;
wire del_eject = del_done & tape_ready & ~new_tape & (del_crc == tape_crc) & (del_len == tape_len);

/////////////////  TAPE  //////////////////////////

// The tape image is mounted on SD slot 0; read it into the buffer.
// img_size 0 means the tape was ejected.
reg         tape_dl = 0;      // reading the image
reg         tape_eject;       // pulse
reg  [31:0] tl_lba;
reg         tl_rd = 0;
wire        tl_ack;
reg  [31:0] tl_size;
reg  [22:0] tl_nsec;
wire [31:0] tl_pos  = {tl_lba[22:0], sd_buff_addr[8:0]};
wire        tl_byte = tape_dl & tl_ack & sd_buff_wr & (tl_pos < tl_size);  // one image byte

reg old_eject;
always @(posedge clk_sys) begin
	reg ack_seen;

	old_eject  <= status[16];
	tape_eject <= (~old_eject & status[16]) | del_eject;   // OSD "Eject Tape", or the tape was deleted
	if(img_mounted[0]) begin
		tl_rd   <= 0;
		tape_dl <= 0;
		if(|img_size) begin
			tl_size  <= (|img_size[63:32]) ? 32'hFFFFFFFF : img_size[31:0];
			tl_nsec  <= (|img_size[63:32]) ? 23'h7FFFFF : (img_size[31:0] + 32'd511) >> 9;
			tl_lba   <= 0;
			tl_rd    <= 1;
			tape_dl  <= 1;
			ack_seen <= 0;
		end
		else tape_eject <= 1;
	end
	else if(tape_dl) begin
		if(tl_ack) begin
			tl_rd    <= 0;
			ack_seen <= 1;
		end
		else if(ack_seen) begin
			ack_seen <= 0;
			if(tl_lba[22:0] + 1'd1 < tl_nsec) begin
				tl_lba <= tl_lba + 1'd1;
				tl_rd  <= 1;
			end
			else tape_dl <= 0;
		end
	end
end

// SAVE with no tape inserted starts a new, empty tape; the script names the
// file after the first program saved on it.
reg         new_tape = 0;
reg  [31:0] new_token;
reg  [31:0] free_cnt;
reg         new_start, new_end;  // pulses, like the start and end of reading an image
reg         new_pend = 0;        // between new_start and new_end
reg   [3:0] new_init = 0;        // TZX file header bytes still to write

// a new TZX tape starts with the TZX file header: "ZXTape!", 0x1A, version 1.20
reg   [7:0] tzx_hdr;
always @(*) begin
	case(4'd10 - new_init)
		0: tzx_hdr = "Z"; 1: tzx_hdr = "X"; 2: tzx_hdr = "T"; 3: tzx_hdr = "a"; 4: tzx_hdr = "p";
		5: tzx_hdr = "e"; 6: tzx_hdr = "!"; 7: tzx_hdr = 8'h1A; 8: tzx_hdr = 8'h01; default: tzx_hdr = 8'd20;
	endcase
end
always @(posedge clk_sys) free_cnt <= free_cnt + 1'd1;

reg         tape_ready = 0;
reg  [17:0] tape_size;
reg         tape_tzx = 0;  // image is TZX, not TAP

// 128KB buffer holding the inserted .TAP or .TZX image
wire [16:0] tape_addr;
wire  [7:0] tape_data;
dpram #(17) tape_ram
(
	.clock(clk_sys),
	.address_a(tape_dl ? tl_pos[16:0] : |new_init ? {13'd0, 4'd10 - new_init} : save_waddr),
	.data_a(tape_dl ? sd_buff_dout : |new_init ? tzx_hdr : save_wdata),
	.wren_a(tape_dl ? (tl_byte & ~|tl_pos[31:17]) : |new_init | save_we),
	.address_b(save_busy ? save_raddr : tape_addr),
	.q_b(tape_data),
	.oe_b_n(1'b0)
);

reg tape_play_man = 0; // toggled by "Tape Play/Pause"
reg tape_rewind;
always @(posedge clk_sys) begin
	reg old_dl, old_play, old_rew;

	old_dl   <= tape_dl;
	old_play <= status[12];
	old_rew  <= status[13];

	new_start <= 0;
	new_end   <= 0;
	if(new_init) new_init <= new_init - 1'd1;
	else if(new_pend & ~new_start) begin
		new_end  <= 1;
		new_pend <= 0;
	end
	if(tape_save & ~tape_ready & ~tape_dl & ~new_pend) begin
		// "New Tape Format": TAP, or TZX with its 10-byte file header
		new_start <= 1;
		new_pend  <= 1;
		new_tape  <= 1;
		new_token <= free_cnt;
		tape_tzx  <= status[18];
		tape_size <= status[18] ? 18'd10 : 18'd0;
		new_init  <= status[18] ? 4'd10 : 4'd0;
		tape_ready <= 1;
	end
	if((~old_dl & tape_dl) | tape_eject) begin
		tape_ready <= 0;
		new_tape   <= 0;
	end
	if(tl_byte) tape_size <= (|tl_pos[31:17]) ? 18'h20000 : {1'b0, tl_pos[16:0]} + 1'd1;
	if(old_dl & ~tape_dl) tape_ready <= 1;
	if(save_size_set) tape_size <= save_size;

	// a TZX image starts with "ZXTape!"
	if(tl_byte) begin
		case(tl_pos)
			0: tape_tzx <= (sd_buff_dout == "Z");
			1: if(sd_buff_dout != "X") tape_tzx <= 0;
			2: if(sd_buff_dout != "T") tape_tzx <= 0;
			3: if(sd_buff_dout != "a") tape_tzx <= 0;
			4: if(sd_buff_dout != "p") tape_tzx <= 0;
			5: if(sd_buff_dout != "e") tape_tzx <= 0;
			6: if(sd_buff_dout != "!") tape_tzx <= 0;
		endcase
	end

	if(~old_play & status[12]) tape_play_man <= ~tape_play_man;
	if(tape_dl | tape_eject | (tape_at_end & ~wrap_on) | tzx_stop | auto_rw) tape_play_man <= 0;

	tape_rewind <= (~old_rew & status[13]) | auto_rw | wrap_rw;
end

// Auto Play: run the tape while the ROM LOAD routine is executing
reg [16:0] load_timer = 0;
always @(posedge clk_sys) begin
	if(tape_load) load_timer <= '1;
	else if(ce_run && load_timer) load_timer <= load_timer - 1'd1;
end

wire tape_playing = tape_ready & ~tape_at_end & ~save_busy & (tape_play_man | (status[6] & |load_timer));

// Tape Auto Rewind: once the ROM has stopped loading for 1 s of CPU time
// (loaded, BREAK or error), rewind, unless LOAD was given a blank name, which
// means "the next file". If the tape ends while the ROM is still searching,
// rewind and carry on.
wire       auto_rewind = status[19];
wire       wrap_on     = auto_rewind & |load_timer;
wire [7:0] name0;
reg [21:0] idle_cnt;
reg        load_seen = 0;
reg        auto_rw, wrap_rw;
always @(posedge clk_sys) begin
	reg old_end;

	auto_rw <= 0;
	wrap_rw <= 0;
	old_end <= tape_at_end;

	if(tape_load) begin
		load_seen <= 1;
		idle_cnt  <= 0;
	end
	else if(ce_run && load_seen) begin
		if(idle_cnt < 22'd3250000) idle_cnt <= idle_cnt + 1'd1;
		else begin
			load_seen <= 0;
			if(auto_rewind && name0 != 8'h00 && name0 != 8'h20) auto_rw <= 1;
		end
	end
	if(tape_dl | tape_eject) load_seen <= 0;

	if(wrap_on && tape_ready && ~old_end && tape_at_end) wrap_rw <= 1;
end
assign fast_load = (status[15] & tape_playing) | (status[15] & |save_timer) | sp_active;

// Recorder: listen to MIC while the ROM SAVE routine is executing
reg [16:0] save_timer = 0;
always @(posedge clk_sys) begin
	if(tape_save) save_timer <= '1;
	else if(ce_run && save_timer) save_timer <= save_timer - 1'd1;
end

wire        tape_save;
wire [16:0] save_waddr, save_raddr;
wire  [7:0] save_wdata;
wire        save_we, save_busy;
wire        save_size_set;
wire [17:0] save_size, save_seek;

reg old_dl_s;
always @(posedge clk_sys) old_dl_s <= tape_dl;

tape_save tape_save_rec
(
	.clk(clk_sys),
	.ce(ce_run),
	.save_active(|save_timer),
	.mic(mic),

	.tape_ready(tape_ready),
	.tape_tzx(tape_tzx),
	.new_tape(new_tape),
	.new_token(new_token),
	.tape_size(tape_size),
	.dl_start((~old_dl_s & tape_dl) | new_start),
	.dl_wr(tl_byte),
	.dl_data(sd_buff_dout),
	.dl_end((old_dl_s & ~tape_dl) | new_end),

	.waddr(save_waddr),
	.wdata(save_wdata),
	.we(save_we),
	.raddr(save_raddr),
	.rdata(tape_data),
	.busy(save_busy),
	.crc(tape_crc),
	.len(tape_len),
	.req(save_req),
	.sd_hold(del_busy | poll_busy | snap_busy),

	.size_set(save_size_set),
	.new_size(save_size),
	.seek_pos(save_seek),

	.img_mounted(img_mounted[1]),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba(sd_lba),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_din(sd_buff_din),

	.info_req(tape_info_req),
	.info(tape_info)
);
wire        tape_load;

wire [16:0] tap_addr, tzx_addr;
wire        tap_ear,  tzx_ear;
wire        tap_end,  tzx_end;
wire        tzx_stop;

assign tape_addr   = tape_tzx ? tzx_addr : tap_addr;
wire   tape_in     = tape_tzx ? tzx_ear  : tap_ear;
wire   tape_at_end = tape_tzx ? tzx_end  : tap_end;

tape tape
(
	.clk(clk_sys),
	.ce(ce_run),
	.play(tape_playing),
	.rewind(tape_rewind),
	.seek(save_size_set),
	.seek_pos(save_seek),
	.tape_ready(tape_ready & ~tape_tzx),
	.tape_size(tape_size),
	.addr(tap_addr),
	.din(tape_data),
	.ear(tap_ear),
	.at_end(tap_end)
);

tzx tzx
(
	.clk(clk_sys),
	.ce(ce_run),
	.play(tape_playing),
	.rewind(tape_rewind),
	.seek(save_size_set),
	.seek_pos(save_seek),
	.tape_ready(tape_ready & tape_tzx),
	.tape_size(tape_size),
	.addr(tzx_addr),
	.din(tape_data),
	.ear(tzx_ear),
	.at_end(tzx_end),
	.stop_req(tzx_stop)
);

///////////////////////////////////////////////////

wire reset = RESET | status[0] | buttons[1] | |mem_rst;

wire mic,spk;

wire [7:0] kbd_row;
wire [4:0] kbd_col, kbd_col_kb, kbd_col_sp;
assign kbd_col = sp_active ? kbd_col_sp : kbd_col_kb;   // the keyboard is ignored while spooling
wire [3:0] vid_r, vid_g, vid_b;
wire [13:0] ay_a, ay_b, ay_c;

// system variable writes (for the spooler) and the spooling frame interrupt
wire        sv_we;
wire  [5:0] sv_addr;
wire  [7:0] sv_data;
wire        int_fast, int_fast_n;

wire [7:0] ay_regs[17];
wire [2:0] snap_xs_space;
wire [1:0] snap_xs_pg;

ace ace
(
	.*,
	.loader_addr(ld_state ? st_addr : loader_addr),
	.xs_space(loader_en ? (ld_state ? st_sp : 3'd0) : snap_xs_space),
	.xs_pg(loader_en ? st_pg : snap_xs_pg),
	.ay_ld_idx(st_k[4:0]),
	.clk(clk_sys),
	.no_wait(|turbo | fast_load),
	.reset(reset|loader_reset)
);

keyboard keyboard (.*, .kbd_col(kbd_col_kb));

/////////////////  SPOOL  /////////////////////////

wire [31:0] sp_lba;
wire        sp_rd, sp_ack, sp_active;
wire        sp_info_req;
wire  [7:0] sp_info;
// "Stop Spool", or Esc pressed on the keyboard
reg  old_stop, old_ps2;
wire esc_down  = (old_ps2 != ps2_key[10]) & ps2_key[9] & (ps2_key[7:0] == 8'h76);
always @(posedge clk_sys) begin
	old_stop <= status[20];
	old_ps2  <= ps2_key[10];
end

spool spool
(
	.clk(clk_sys),
	.reset(reset),
	.img_mounted(img_mounted[3]),
	.img_size(img_size),
	.stop((~old_stop & status[20]) | esc_down),
	.lba(sp_lba),
	.rd(sp_rd),
	.ack(sp_ack),
	.sd_buff_addr(sd_buff_addr[8:0]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr(sd_buff_wr),
	.sv_we(sv_we),
	.sv_addr(sv_addr),
	.sv_data(sv_data),
	.kbd_row(kbd_row),
	.kbd_col(kbd_col_sp),
	.active(sp_active),
	.info_req(sp_info_req),
	.info(sp_info)
);

// While spooling the CPU runs 8x, and the frame interrupt comes every 65000
// CPU T-states (50 Hz of Ace time) instead of from the video, so the ROM's
// key timing is unchanged and spooling is 8x faster.
reg [15:0] int_cnt;
assign int_fast   = sp_active;
assign int_fast_n = (int_cnt >= 16'd256);
always @(posedge clk_sys) begin
	if(!sp_active) int_cnt <= 0;
	else if(ce_run) int_cnt <= (int_cnt == 16'd64999) ? 16'd0 : int_cnt + 1'd1;
end

wire [1:0] scale = status[3:2];

// the beeper (and tape) on both sides; with the Expansion its sound chip: A left,
// B right, C on both
wire [15:0] beep = {1'b0, spk, mic, tape_in & tape_playing & ~status[7], 12'd0};
assign AUDIO_L = beep + ay_a + ay_c;
assign AUDIO_R = beep + ay_b + ay_c;
assign AUDIO_MIX = 0;
assign AUDIO_S = 0;

wire hsync, vsync, hblank, vblank;
assign CLK_VIDEO = clk_sys;
assign VGA_SL = scale ? scale - 1'd1 : 2'd0;
assign VGA_F1 = 0;

video_mixer #(320, 1) mixer
(
	.*,
	.freeze_sync(),
	.hq2x(scale == 1),
	.scandoubler(scale || forced_scandoubler),
	.gamma_bus(),

	.R(vid_r),
	.G(vid_g),
	.B(vid_b),

	.HSync(~hsync),
	.VSync(~vsync),
	.HBlank(hblank),
	.VBlank(vblank)
);

endmodule
