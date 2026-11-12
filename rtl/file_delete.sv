//============================================================================
//  Jupiter Ace OSD "Delete"
//
//  The OSD has no way to delete files, so "Delete" is a file browser
//  slot (SD slot 2): picking a file makes Main_MiSTer open it for the core.
//  This module reads the whole file to get its POSIX cksum CRC, then writes a
//  delete request into sector 1018 of games/JupiterACE/boot1.vhd (SD slot 1).
//  JupiterACE.sh finds the open file with that checksum, moves it to
//  games/JupiterACE/deleted/ (or erases it if it is already there) and writes
//  the answer into the same sector, which this module polls and reports on
//  the OSD.
//
//  Request sector layout:
//      0  "JACEDEL1"
//      8  request counter (LE32)
//      12 state: 2 = request, 3 = deleted, 4 = not deleted (set by the script)
//      16 POSIX cksum CRC of the file (LE32)
//      20 file length (LE32)
//
//  Main_MiSTer caches 32 sectors of reads per disk, so every poll first reads
//  sector 0 and then sector 1018: each read then comes from the file.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module file_delete
(
	input             clk,

	// the picked file: SD slot 2, read only
	input             img_mounted2,
	input             img_mounted1,  // boot1.vhd mounted
	input             img_readonly,
	input      [63:0] img_size,
	output reg [31:0] lba2,
	output reg        rd2,
	input             ack2,

	// boot1.vhd: SD slot 1
	output reg [31:0] lba1,
	output reg        rd1,
	output reg        wr1,
	input             ack1,
	output      [7:0] din1,

	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	input             sd_buff_wr,

	input             other_busy,    // snapshot or tape save is writing to slot 1
	output            busy,          // using slot 1, or about to: the others must not start

	output reg [31:0] del_crc,       // the file that was deleted ...
	output reg [31:0] del_len,
	output reg        deleted,       // ... pulse

	// OSD messages, see the "I" line of CONF_STR
	output reg        info_req,
	output reg  [7:0] info
);

localparam INFO_DELETED  = 8'd9;
localparam INFO_KEPT     = 8'd10;
localparam INFO_NOSCRIPT = 8'd11;
localparam INFO_NOFILE   = 8'd12;

localparam REQ_LBA   = 32'd1018;
localparam FILE_SIZE = 64'd521728; // 1019 sectors

// boot1.vhd is big enough for the request sector
reg file_ok = 0;
always @(posedge clk) if(img_mounted1) file_ok <= ~img_readonly && (img_size >= FILE_SIZE);

// Main_MiSTer mounts games/JupiterACE/boot2.vhd on slot 2 when the core
// starts if an old one is still there: ignore mounts in the first seconds
reg [27:0] start_cnt = 0;
wire       started = start_cnt[27];
always @(posedge clk) if(!started) start_cnt <= start_cnt + 1'd1;

/////////////////  POSIX cksum  /////////////////

function [31:0] crc8(input [31:0] c, input [7:0] d);
	integer i;
	begin
		crc8 = c;
		for(i = 7; i >= 0; i = i - 1)
			crc8 = {crc8[30:0], 1'b0} ^ ((crc8[31] ^ d[i]) ? 32'h04C11DB7 : 32'd0);
	end
endfunction

/////////////////  request sector  /////////////////

reg [31:0] seq = 0;
reg [31:0] crc, len, nsec, lsh;
reg  [7:0] answer;

reg [7:0] hbyte;
always @(*) begin
	case(sd_buff_addr)
		0: hbyte = "J";  1: hbyte = "A";  2: hbyte = "C";  3: hbyte = "E";
		4: hbyte = "D";  5: hbyte = "E";  6: hbyte = "L";  7: hbyte = "1";
		8: hbyte = seq[7:0];   9: hbyte = seq[15:8];   10: hbyte = seq[23:16];   11: hbyte = seq[31:24];
		12: hbyte = 8'd2;
		16: hbyte = crc[7:0];  17: hbyte = crc[15:8];  18: hbyte = crc[23:16];  19: hbyte = crc[31:24];
		20: hbyte = len[7:0];  21: hbyte = len[15:8];  22: hbyte = len[23:16];  23: hbyte = len[31:24];
		default: hbyte = 0;
	endcase
end
assign din1 = hbyte;

/////////////////  state machine  /////////////////

localparam S_IDLE  = 4'd0;
localparam S_READ  = 4'd1;   // read the picked file
localparam S_CRC   = 4'd2;   // append the length, invert
localparam S_GRANT = 4'd3;   // wait for slot 1
localparam S_REQ   = 4'd4;   // write the request
localparam S_WAIT  = 4'd5;   // wait before a poll
localparam S_POLL0 = 4'd6;   // read sector 0 (defeats Main's read cache)
localparam S_POLL1 = 4'd7;   // read the request sector
localparam S_CHECK = 4'd8;

reg  [3:0] state = S_IDLE;
reg        ack_seen;
reg [24:0] tmr;        // ~0.65 s at 52 MHz
reg  [3:0] polls;

assign busy = (state >= S_GRANT);

wire [31:0] pos = {lba2[22:0], sd_buff_addr};

always @(posedge clk) begin
	info_req <= 0;
	deleted  <= 0;

	case(state)
		S_IDLE:
			if(img_mounted2 && started && |img_size) begin
				if(!file_ok) begin
					info <= INFO_NOFILE; info_req <= 1;
				end
				else begin
					len      <= (|img_size[63:32]) ? 32'hFFFFFFFF : img_size[31:0];
					nsec     <= (|img_size[63:32]) ? 32'h007FFFFF : (img_size[31:0] + 32'd511) >> 9;
					crc      <= 0;
					lba2     <= 0;
					rd2      <= 1;
					ack_seen <= 0;
					state    <= S_READ;
				end
			end

		S_READ: begin
				if(ack2 & sd_buff_wr & (pos < len)) crc <= crc8(crc, sd_buff_dout);
				if(ack2) begin
					rd2      <= 0;
					ack_seen <= 1;
				end
				else if(ack_seen) begin
					ack_seen <= 0;
					if(lba2 + 1'd1 < nsec) begin
						lba2 <= lba2 + 1'd1;
						rd2  <= 1;
					end
					else begin
						lsh   <= len;
						state <= S_CRC;
					end
				end
			end

		S_CRC:
			if(lsh) begin
				crc <= crc8(crc, lsh[7:0]);
				lsh <= lsh >> 8;
			end
			else begin
				crc   <= ~crc;
				state <= S_GRANT;
			end

		S_GRANT:
			if(!other_busy) begin
				seq      <= seq + 1'd1;
				lba1     <= REQ_LBA;
				wr1      <= 1;
				ack_seen <= 0;
				state    <= S_REQ;
			end

		S_REQ:
			if(ack1) begin
				wr1      <= 0;
				ack_seen <= 1;
			end
			else if(ack_seen) begin
				ack_seen <= 0;
				polls    <= 0;
				tmr      <= '1;
				state    <= S_WAIT;
			end

		S_WAIT:
			if(tmr) tmr <= tmr - 1'd1;
			else if(!other_busy) begin
				lba1     <= 0;
				rd1      <= 1;
				ack_seen <= 0;
				state    <= S_POLL0;
			end

		S_POLL0:
			if(ack1) begin
				rd1      <= 0;
				ack_seen <= 1;
			end
			else if(ack_seen) begin
				ack_seen <= 0;
				lba1     <= REQ_LBA;
				rd1      <= 1;
				answer   <= 0;
				state    <= S_POLL1;
			end

		S_POLL1: begin
				if(ack1 & sd_buff_wr & (sd_buff_addr == 9'd12)) answer <= sd_buff_dout;
				if(ack1) begin
					rd1      <= 0;
					ack_seen <= 1;
				end
				else if(ack_seen) begin
					ack_seen <= 0;
					state    <= S_CHECK;
				end
			end

		S_CHECK: begin
				polls <= polls + 1'd1;
				tmr   <= '1;
				state <= S_WAIT;
				if(answer == 8'd3) begin
					info    <= INFO_DELETED; info_req <= 1;
					del_crc <= crc;
					del_len <= len;
					deleted <= 1;
					state   <= S_IDLE;
				end
				else if(answer == 8'd4) begin
					info  <= INFO_KEPT; info_req <= 1;
					state <= S_IDLE;
				end
				else if(polls == 4'd12) begin    // ~8 s: the script is not running
					info  <= INFO_NOSCRIPT; info_req <= 1;
					state <= S_IDLE;
				end
			end
	endcase
end

endmodule
