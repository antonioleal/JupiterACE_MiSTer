//============================================================================
//  Jupiter Ace snapshot saver
//
//  On a request from the OSD, stops the CPU at an instruction boundary,
//  builds an .ACE snapshot of 2000-FFFF and writes it to the snapshot file
//  that Main_MiSTer mounts on SD slot 1 when the core starts
//  (games/JupiterACE/boot1.vhd, created by JupiterACE.sh). The script
//  copies each new snapshot to games/JupiterACE/SNAPnnn.ace.
//
//  .ACE layout: a memory dump from 2000h, run-length packed. 2000-23FF (a
//  mirror of the video RAM) holds settings and the Z80 registers:
//    2000 01 80        2080 RAM top (LE32)    208C/2090 03 (frame rates)
//    2094 FD FD        2100.. AF BC DE HL IX IY SP PC AF' BC' DE' HL' IM
//                      IFF1 IFF2 I R, one LE32 each
//  Packing: ED n b = n copies of b (n = 1..240), used for runs of 3 or more
//  and for every ED byte; ED 00 ends the file.
//
//  Snapshot file layout (512-byte sectors):
//    sector 0  : header
//      0  "JACESNP1"
//      8  snapshot counter (LE32)
//      12 state: 1 = being written, 2 = complete (the script sets 3 = copied)
//      16 length of the .ACE data (LE32)
//    sector 1+ : the .ACE data
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module snap_save
(
	input             clk,
	input             reset,
	input             trig,         // pulse: take a snapshot

	// CPU and memory
	output reg        hold,         // stop the CPU at the next instruction boundary
	input             held,
	input             halted,
	input     [211:0] cpu_reg,      // IFF2, IFF1, IM, IY, HL', DE', BC', IX, HL, DE, BC, PC, SP, R, I, F', A', F, A
	output reg        mem_en,
	output reg [15:0] mem_addr,
	input       [7:0] mem_data,     // one clock after mem_addr

	// snapshot file on SD slot 1
	input             img_mounted,
	input             img_readonly,
	input      [63:0] img_size,
	output reg [31:0] sd_lba,
	output reg        sd_wr,
	input             sd_ack,
	input       [8:0] sd_buff_addr,
	output      [7:0] sd_buff_din,

	output            busy,
	input             sd_hold,      // slot 1 is in use: wait before writing

	// OSD messages, see the "I" line of CONF_STR
	output reg        info_req,
	output reg  [7:0] info
);

localparam INFO_SAVED  = 8'd6;
localparam INFO_NOFILE = 8'd7;
localparam INFO_BUSY   = 8'd8;

localparam FILE_SECTORS = 257;  // header + 128 KB, more than the worst case packing

// the snapshot file is usable
reg file_ok = 0;
always @(posedge clk) begin
	if(img_mounted) file_ok <= ~img_readonly && (img_size >= FILE_SECTORS * 512);
end

/////////////////  CPU state at the stop  /////////////////

reg [211:0] r;
reg         halted_r;
wire [15:0] pc = r[79:64] - (halted_r ? 16'd1 : 16'd0);  // resume inside HALT

// the byte of the 2000-23FF page at the source address
reg [16:0] a;          // source address
reg  [7:0] page;
always @(*) begin
	case(a[9:0])
		'h000: page = 8'h01;      'h001: page = 8'h80;
		'h082: page = 8'h01;                                // RAM top 10000h
		'h08C: page = 8'h03;      'h090: page = 8'h03;
		'h094: page = 8'hFD;      'h095: page = 8'hFD;
		'h100: page = r[15:8];    'h101: page = r[7:0];     // F, A
		'h104: page = r[87:80];   'h105: page = r[95:88];   // C, B
		'h108: page = r[103:96];  'h109: page = r[111:104]; // E, D
		'h10C: page = r[119:112]; 'h10D: page = r[127:120]; // L, H
		'h110: page = r[135:128]; 'h111: page = r[143:136]; // IX
		'h114: page = r[199:192]; 'h115: page = r[207:200]; // IY
		'h118: page = r[55:48];   'h119: page = r[63:56];   // SP
		'h11C: page = pc[7:0];    'h11D: page = pc[15:8];   // PC
		'h120: page = r[31:24];   'h121: page = r[23:16];   // F', A'
		'h124: page = r[151:144]; 'h125: page = r[159:152]; // C', B'
		'h128: page = r[167:160]; 'h129: page = r[175:168]; // E', D'
		'h12C: page = r[183:176]; 'h12D: page = r[191:184]; // L', H'
		'h130: page = {6'd0, r[209:208]};                   // IM
		'h134: page = {7'd0, r[210]};                       // IFF1
		'h138: page = {7'd0, r[211]};                       // IFF2
		'h13C: page = r[39:32];                             // I
		'h140: page = r[47:40];                             // R
		'h144: page = 8'h80;
		default: page = 8'h00;
	endcase
end

/////////////////  sector buffer  /////////////////

reg [7:0] obuf[512];
reg [8:0] oidx;        // next free byte in obuf
reg [7:0] obuf_q;
always @(posedge clk) obuf_q <= obuf[sd_buff_addr];

reg [31:0] seq = 0;
reg  [7:0] hstate;
reg [16:0] olen;       // .ACE bytes so far

reg [7:0] hbyte;
always @(*) begin
	case(sd_buff_addr)
		0: hbyte = "J";  1: hbyte = "A";  2: hbyte = "C";  3: hbyte = "E";
		4: hbyte = "S";  5: hbyte = "N";  6: hbyte = "P";  7: hbyte = "1";
		8: hbyte = seq[7:0];   9: hbyte = seq[15:8];   10: hbyte = seq[23:16];   11: hbyte = seq[31:24];
		12: hbyte = hstate;
		16: hbyte = olen[7:0]; 17: hbyte = olen[15:8]; 18: hbyte = {7'd0, olen[16]};
		default: hbyte = 0;
	endcase
end

assign sd_buff_din = !sd_lba ? hbyte : obuf_q;

/////////////////  packer and writer  /////////////////

localparam S_IDLE  = 4'd0;
localparam S_HOLD  = 4'd1;
localparam S_SD    = 4'd2;   // write sector sd_lba, then go to ret
localparam S_FETCH = 4'd3;
localparam S_WAIT  = 4'd4;
localparam S_BYTE  = 4'd5;
localparam S_NEXT  = 4'd6;
localparam S_EMIT  = 4'd7;
localparam S_FIN   = 4'd8;
localparam S_LAST  = 4'd9;
localparam S_HDR2  = 4'd10;
localparam S_DONE  = 4'd11;

reg  [3:0] state = S_IDLE;
reg  [3:0] ret, emit_ret;
reg        ack_seen;
reg [26:0] tmo;
reg  [1:0] wt;
reg  [7:0] b;          // source byte
reg  [7:0] rb, rc;     // current run: byte, count (0 = none)
reg  [7:0] q[5];       // bytes waiting to go into obuf
reg  [2:0] qn, qi;
reg [16:0] osec;       // data sectors written

assign busy = (state != S_IDLE);

// queue the current run (rb, rc) at q[n]; returns the number of bytes queued
task run_out(input [2:0] n, output [2:0] cnt);
begin
	if(rc >= 3 || rb == 8'hED) begin
		q[n] <= 8'hED; q[n + 1'd1] <= rc; q[n + 2'd2] <= rb; cnt = 3;
	end
	else if(rc == 2) begin
		q[n] <= rb; q[n + 1'd1] <= rb; cnt = 2;
	end
	else if(rc == 1) begin
		q[n] <= rb; cnt = 1;
	end
	else cnt = 0;
end
endtask

always @(posedge clk) begin
	reg [2:0] cnt;

	info_req <= 0;

	if(reset && state == S_HOLD) begin
		hold  <= 0;
		state <= S_IDLE;
	end
	else case(state)
		S_IDLE:
			if(trig) begin
				if(!file_ok) begin
					info <= INFO_NOFILE; info_req <= 1;
				end
				else begin
					hold  <= 1;
					tmo   <= '1;
					state <= S_HOLD;
				end
			end

		S_HOLD:
			if(held && !sd_hold) begin
				r        <= cpu_reg;
				halted_r <= halted;
				mem_en   <= 1;
				a        <= 17'h2000;
				rc       <= 0;
				oidx     <= 0;
				osec     <= 0;
				olen     <= 0;
				seq      <= seq + 1'd1;
				hstate   <= 1;
				sd_lba   <= 0;          // header first, marked "being written"
				sd_wr    <= 1;
				ack_seen <= 0;
				ret      <= S_FETCH;
				state    <= S_SD;
			end
			else if(tmo) tmo <= tmo - 1'd1;
			else begin
				hold  <= 0;
				info  <= INFO_BUSY; info_req <= 1;
				state <= S_IDLE;
			end

		S_SD:
			if(sd_ack) begin
				sd_wr    <= 0;
				ack_seen <= 1;
			end
			else if(ack_seen) begin
				ack_seen <= 0;
				state    <= ret;
			end

		S_FETCH: begin
				mem_addr <= a[15:0];
				wt       <= 2;
				state    <= S_WAIT;
			end

		S_WAIT:
			if(wt) wt <= wt - 1'd1;
			else begin
				b     <= (a < 17'h2400) ? page : mem_data;
				state <= S_BYTE;
			end

		S_BYTE:
			if(rc && b == rb && rc != 8'd240) begin
				rc    <= rc + 1'd1;
				state <= S_NEXT;
			end
			else if(!rc) begin
				rb    <= b;
				rc    <= 1;
				state <= S_NEXT;
			end
			else begin
				run_out(0, cnt);
				qn       <= cnt;
				qi       <= 0;
				rb       <= b;
				rc       <= 1;
				emit_ret <= S_NEXT;
				state    <= S_EMIT;
			end

		S_NEXT:
			if(a == 17'hFFFF) state <= S_FIN;
			else begin
				a     <= a + 1'd1;
				state <= S_FETCH;
			end

		S_EMIT:
			if(qi == qn) state <= emit_ret;
			else begin
				obuf[oidx] <= q[qi];
				qi         <= qi + 1'd1;
				oidx       <= oidx + 1'd1;
				olen       <= olen + 1'd1;
				if(oidx == 9'd511) begin
					// sector full
					sd_lba   <= osec + 1'd1;
					osec     <= osec + 1'd1;
					sd_wr    <= 1;
					ack_seen <= 0;
					ret      <= S_EMIT;
					state    <= S_SD;
				end
			end

		S_FIN: begin
				// the last run, then the end marker
				run_out(0, cnt);
				q[cnt]        <= 8'hED;
				q[cnt + 1'd1] <= 8'h00;
				qn            <= cnt + 3'd2;
				qi            <= 0;
				mem_en        <= 0;
				emit_ret      <= S_LAST;
				state         <= S_EMIT;
			end

		S_LAST:
			if(oidx) begin
				sd_lba   <= osec + 1'd1;
				osec     <= osec + 1'd1;
				oidx     <= 0;
				sd_wr    <= 1;
				ack_seen <= 0;
				ret      <= S_HDR2;
				state    <= S_SD;
			end
			else state <= S_HDR2;

		S_HDR2: begin
				hstate   <= 2;
				sd_lba   <= 0;
				sd_wr    <= 1;
				ack_seen <= 0;
				ret      <= S_DONE;
				state    <= S_SD;
			end

		S_DONE: begin
				hold     <= 0;
				info     <= INFO_SAVED;
				info_req <= 1;
				state    <= S_IDLE;
			end
	endcase
end

endmodule
