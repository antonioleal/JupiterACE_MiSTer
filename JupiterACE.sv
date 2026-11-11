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
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
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
	"JupiterACE;;",
	"-;",
	"F1,ACE,Load Snapshot;",
	"RE,Save Snapshot;",
	"RL,Save Dictionary;",
	"S0,TAPTZX,Insert Tape;",
	"TG,Eject Tape;",
	"TC,Tape Play/Pause;",
	"TD,Tape Rewind;",
	"O6,Tape Autoplay,Off,On;",
	"OJ,Tape Auto Rewind,Off,On;",
	"O7,Tape Sound,On,Off;",
	"OF,Tape Fast Load,Off,On;",
	"OH,Tape Fast Save,Off,On;",
	"OI,New Tape Format,TAP,TZX;",
	"-;",
	"S3,FTHFS F,Spool Forth File;",
	"TK,Stop Spool;",
	"-;",
	"S2,TAPTZXACE,Delete File;",
	"-;",
	"O89,Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O23,Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%;",
	"OAB,Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer;",
	"-;",
	"O45,CPU Speed,Normal,x2,x4;",
	"R0,Reset;",
	"J,Fire;",
	"I,Tape saved,New tape created,Tape full: save discarded,Save failed: bad block,Save failed: run JupiterACE.sh,Snapshot saved,Snapshot: run JupiterACE.sh,Snapshot failed: CPU busy,File deleted,Delete failed: see log,JupiterACE.sh not running,Delete: run JupiterACE.sh,Tape save failed: see log,Snapshot failed: see log,Spool done,Spool done with errors,Spool stopped: line not OK,Spool stopped,Dictionary saved,Dictionary failed: see log;",
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
wire       fast_load;  // Tape Fast Load/Save: CPU and tape run 8x while the tape plays or records

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

	.info_req(tape_msg | snap_msg | del_info_req | poll_info_req | sp_info_req | new_start),
	.info(new_start ? 8'd2 : tape_msg ? tape_info : snap_msg ? snap_info : del_info_req ? del_info : poll_info_req ? poll_info : sp_info)
);

// SD slot 0: tape image (S0 option)
// SD slot 1: games/JupiterACE/boot1.vhd, mounted when the core starts:
//            sectors 0-256 snapshots, 257-513 tape saves, 514 delete
//            requests. Only one of the three writers uses it at a time.
// SD slot 2: the file picked in "Delete File" (S2 option)
// SD slot 3: the file picked in "Spool Forth File" (S3 option)
wire  [3:0] img_mounted;
wire        img_readonly;
wire [63:0] img_size;
wire [31:0] sd_lba, snap_lba;
wire        sd_wr, sd_ack, snap_wr, snap_ack;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_din, snap_buff_din, sd_buff_dout;
wire        sd_buff_wr;
wire [31:0] f_lba  = snap_busy ? snap_lba : del_busy ? del_lba1 : poll_busy ? poll_lba : sd_lba + 32'd257;
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

always @(posedge clk_sys) begin
	reg [7:0] cnt = 0;
	reg [1:0] status = 0;
	reg       old_download;
	integer   timeout = 0;

	old_download <= ioctl_download;
	
	loader_reset <= 0;
	if(~old_download && ioctl_download && ioctl_index[5:0] == 1) begin
		loader_addr <= 'h2000;
		status <= 0;
		loader_reset <=1;
		ioctl_wait <= 1;
		timeout <= 3000000;
		cnt <= 0;
	end
	
	loader_wr <= 0;
	if(loader_wr) loader_addr <= loader_addr + 1'd1;

	if(ioctl_wr && ioctl_index[5:0] == 1) begin
		loader_en <= 1;
		case(status)
			0: if(ioctl_dout == 'hED) status <= 1;
				else begin
					loader_wr <= 1;
					loader_data <= ioctl_dout;
				end
			1: begin
					cnt <= ioctl_dout;
					status <= ioctl_dout ? 2'd2 : 2'd3; // cnt = 0 => stop
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

	if(old_download & ~ioctl_download) loader_en <= 0;
	if(reset) ioctl_wait <= 0;
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

// Autoplay: run the tape while the ROM LOAD routine is executing
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
assign fast_load = (status[15] & tape_playing) | (status[17] & |save_timer) | sp_active;

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

wire reset = RESET | status[0] | buttons[1];

wire mic,spk;

wire [7:0] kbd_row;
wire [4:0] kbd_col, kbd_col_kb, kbd_col_sp;
assign kbd_col = sp_active ? kbd_col_sp : kbd_col_kb;   // the keyboard is ignored while spooling
wire       video_out;

// system variable writes (for the spooler) and the spooling frame interrupt
wire        sv_we;
wire  [5:0] sv_addr;
wire  [7:0] sv_data;
wire        int_fast, int_fast_n;

ace ace
(
	.*,
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

assign AUDIO_L = {1'b0, spk, mic, tape_in & tape_playing & ~status[7], 12'd0};
assign AUDIO_R = AUDIO_L;
assign AUDIO_MIX = 0;
assign AUDIO_S = 0;

wire hsync, vsync, hblank, vblank;
assign CLK_VIDEO = clk_sys;
assign VGA_SL = scale ? scale - 1'd1 : 2'd0;
assign VGA_F1 = 0;

video_mixer #(280, 1) mixer
(
	.*,
	.freeze_sync(),
	.hq2x(scale == 1),
	.scandoubler(scale || forced_scandoubler),
	.gamma_bus(),

	.R({4{video_out}}),
	.G({4{video_out}}),
	.B({4{video_out}}),

	.HSync(~hsync),
	.VSync(~vsync),
	.HBlank(hblank),
	.VBlank(vblank)
);

endmodule
