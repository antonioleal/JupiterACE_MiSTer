//============================================================================
//  Jupiter Ace tape recorder
//
//  Decodes the MIC output while the ROM SAVE routine (0x1820) runs, appends
//  each saved program (header block + data block) to the tape in the tape
//  buffer, and writes everything saved since the tape was inserted to the
//  tape save area of games/JupiterACE/boot1.vhd (sectors 257-513), which
//  Main_MiSTer mounts on SD slot 1 when the core starts. sd_lba here counts
//  from the start of that area. The JupiterACE.sh script on the MiSTer
//  creates the file and merges the saves into the inserted .tap/.tzx file,
//  or, for a new tape, into a new <program name>.tap.
//
//  Save file layout (512-byte sectors):
//    sector 0  : header
//      0  "JACESAV1"
//      8  save counter (LE32)
//      12 state: 1 = being written, 2 = complete (the script sets 3 = merged)
//      13 format: 0 = TAP, 1 = TZX
//      14 1 = new tape (no file yet): the script names it after the program
//      16 POSIX cksum CRC of the image as inserted (LE32)
//      20 length of the image as inserted (LE32)
//      24 payload length (LE32)
//      28 name of the last saved program (10 bytes)
//      40 new tape token (LE32): tells new tapes of different sessions apart
//    sector 1+ : payload, the blocks saved since the tape was inserted, in the
//                image's own format: TAP blocks, or TZX 0x11 (turbo data)
//                blocks carrying the Ace ROM's own timings
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module tape_save
(
	input             clk,
	input             ce,           // one pulse per CPU T-state

	input             save_active,  // CPU is in the ROM SAVE routine
	input             mic,

	// inserted tape
	input             tape_ready,
	input             tape_tzx,
	input             new_tape,     // the tape is a new one, not a file
	input      [31:0] new_token,
	input      [17:0] tape_size,    // current length of the image in the buffer
	input             dl_start,     // pulse: tape download begins
	input             dl_wr,
	input       [7:0] dl_data,
	input             dl_end,       // pulse: tape download finished

	// tape buffer
	output reg [16:0] waddr,
	output reg  [7:0] wdata,
	output reg        we,
	output     [16:0] raddr,        // read port, valid while busy
	input       [7:0] rdata,
	output            busy,         // writing the save file
	output            req,          // about to write the save file
	output     [31:0] crc,          // cksum of the image as inserted
	output     [31:0] len,
	input             sd_hold,      // slot 1 is in use: start writing later

	output reg        size_set,     // pulse: the image grew to new_size
	output reg [17:0] new_size,
	output reg [17:0] seek_pos,     // start of the program just saved

	// tape save area of the file on SD slot 1
	input             img_mounted,
	input             img_readonly,
	input      [63:0] img_size,
	output reg [31:0] sd_lba,
	output reg        sd_wr,
	input             sd_ack,
	input       [8:0] sd_buff_addr,
	output      [7:0] sd_buff_din,

	// OSD messages, see the "I" line of CONF_STR
	output reg        info_req,
	output reg  [7:0] info
);

localparam INFO_SAVED   = 8'd1;
localparam INFO_NOTAPE  = 8'd2;
localparam INFO_FULL    = 8'd3;
localparam INFO_BADBLK  = 8'd4;
localparam INFO_NOFILE  = 8'd5;

/////////////////  image checksum (POSIX cksum)  /////////////////

function [31:0] crc8(input [31:0] c, input [7:0] d);
	integer i;
	begin
		crc8 = c;
		for(i = 7; i >= 0; i = i - 1)
			crc8 = {crc8[30:0], 1'b0} ^ ((crc8[31] ^ d[i]) ? 32'h04C11DB7 : 32'd0);
	end
endfunction

reg [31:0] img_crc;
reg [31:0] img_len;
reg [31:0] len_sh;
reg        crc_fin;
reg        sav_ok = 0; // a writable save file is mounted

always @(posedge clk) begin
	if(dl_start) begin
		img_crc <= 0;
		img_len <= 0;
		crc_fin <= 0;
	end
	else if(dl_wr) begin
		img_crc <= crc8(img_crc, dl_data);
		img_len <= img_len + 1'd1;
	end

	// cksum appends the length, least significant byte first, then inverts
	if(dl_end) begin
		len_sh  <= img_len;
		crc_fin <= 1;
	end
	else if(crc_fin) begin
		if(len_sh) begin
			img_crc <= crc8(img_crc, len_sh[7:0]);
			len_sh  <= len_sh >> 8;
		end
		else begin
			img_crc <= ~img_crc;
			crc_fin <= 0;
		end
	end

	// snapshot area + this area (header + 128 KB each)
	if(img_mounted) sav_ok <= ~img_readonly && (img_size >= 64'd263168);
end

/////////////////  MIC decoder  /////////////////
// ROM SAVE timings (T-states): pilot 2011, sync 601 + 791,
// bit 0 = 2 x 801, bit 1 = 2 x 1591, final edge 917.

reg        ev_start, ev_byte, ev_end;
reg  [7:0] ev_data;

reg  [1:0] rstate;
localparam R_IDLE = 0, R_PILOT = 1, R_SYNC2 = 2, R_DATA = 3;

reg [12:0] ticks;      // T-states since the last MIC edge
reg  [8:0] pcnt;
reg        old_mic;
reg        hb, half;
reg  [2:0] bitn;
reg  [7:0] sh;

wire is_pilot = (ticks >= 1800) && (ticks < 2400);
wire is_sync1 = (ticks >=  450) && (ticks <  700);
wire is_sync2 = (ticks >=  700) && (ticks <  950);
wire is_b0    = (ticks >=  600) && (ticks < 1200);
wire is_b1    = (ticks >= 1200) && (ticks < 1800);

always @(posedge clk) begin
	ev_start <= 0;
	ev_byte  <= 0;
	ev_end   <= 0;

	old_mic <= mic;
	if(ce && ~&ticks) ticks <= ticks + 1'd1;

	if(~save_active) begin
		if(rstate == R_DATA) ev_end <= 1;
		rstate <= R_IDLE;
		pcnt   <= 0;
	end
	else if(old_mic != mic) begin
		ticks <= 0;
		case(rstate)
			R_IDLE:
				if(is_pilot) begin
					pcnt <= pcnt + 1'd1;
					if(&pcnt[7:0]) rstate <= R_PILOT;  // 256 pilot half-waves
				end
				else pcnt <= 0;

			R_PILOT:
				if(is_sync1) rstate <= R_SYNC2;
				else if(~is_pilot) begin rstate <= R_IDLE; pcnt <= 0; end

			R_SYNC2:
				if(is_sync2) begin
					rstate   <= R_DATA;
					half     <= 0;
					bitn     <= 0;
					ev_start <= 1;
				end
				else begin rstate <= R_IDLE; pcnt <= 0; end

			R_DATA:
				if(is_b0 | is_b1) begin
					half <= ~half;
					if(~half) hb <= is_b1;
					else begin
						sh   <= {sh[6:0], hb};
						bitn <= bitn + 1'd1;
						if(&bitn) begin
							ev_byte <= 1;
							ev_data <= {sh[6:0], hb};
						end
					end
				end
				else begin
					ev_end <= 1;
					rstate <= R_IDLE;
					pcnt   <= 0;
				end
		endcase
	end
	else if(rstate == R_DATA && ticks > 13'd4000) begin
		ev_end <= 1;          // silence: the block is over
		rstate <= R_IDLE;
		pcnt   <= 0;
	end
	else if(rstate != R_IDLE && ticks > 13'd4000) begin
		rstate <= R_IDLE;
		pcnt   <= 0;
	end
end

/////////////////  append to the tape buffer  /////////////////

reg [17:0] orig_end = 0; // image length as inserted
reg [17:0] cur_end = 0;   // image length including committed programs
reg [17:0] blk_base;   // start of the block being recorded
reg [17:0] hdr_end;    // end of the recorded header block
reg [17:0] pair_base;  // start of the program (header block) being recorded
reg [17:0] wptr;
reg        pair_st = 0;  // 1: header block recorded, waiting for the data block
reg [15:0] nbytes;
reg  [7:0] flag, xsum;
reg        ovf;
reg  [7:0] name[10];
reg  [7:0] lname[10];  // name of the last committed program
reg  [4:0] hw = 0;       // block header write step
reg        hw_commit;
reg [15:0] blen;
reg        commit;

// TZX blocks are 0x11 (turbo data) with the Ace ROM timings, converted to the
// TZX 3.5 MHz T-states (Ace T-states x 14/13): pilot 2011, sync 601/791,
// bit 0 801, bit 1 1591 -> 2166, 647/852, 863, 1713
wire [4:0] hlen = tape_tzx ? 5'd19 : 5'd2;
wire [4:0] hi   = hlen - hw;     // header byte being written

always @(posedge clk) begin
	integer i;

	we       <= 0;
	size_set <= 0;
	info_req <= 0;
	commit   <= 0;

	if(dl_end) begin
		orig_end <= tape_size;
		cur_end  <= tape_size;
		pair_st  <= 0;
	end

	if(hw) begin
		// write the block header in front of the recorded bytes
		we <= 1;
		waddr <= blk_base[16:0] + hi;
		if(tape_tzx) begin
			case(hi)
				0:  wdata <= 8'h11;                          // turbo speed data block
				1:  wdata <= 8'h76; 2:  wdata <= 8'h08;      // pilot pulse 2166
				3:  wdata <= 8'h87; 4:  wdata <= 8'h02;      // sync 1 647
				5:  wdata <= 8'h54; 6:  wdata <= 8'h03;      // sync 2 852
				7:  wdata <= 8'h5F; 8:  wdata <= 8'h03;      // bit 0 863
				9:  wdata <= 8'hB1; 10: wdata <= 8'h06;      // bit 1 1713
				11: wdata <= 8'h00;                          // pilot pulses: 8192 (header), 1024 (data)
				12: wdata <= (flag == 8'h00) ? 8'h20 : 8'h04;
				13: wdata <= 8'h08;                          // bits in the last byte
				14: wdata <= 8'hE8; 15: wdata <= 8'h03;      // 1000 ms pause
				16: wdata <= blen[7:0];                      // data length (24 bit)
				17: wdata <= blen[15:8];
				default: wdata <= 8'h00;
			endcase
		end
		else wdata <= (hw == 2) ? blen[7:0] : blen[15:8];
		hw <= hw - 1'd1;

		if(hw == 1 && hw_commit) begin
			cur_end  <= wptr;
			new_size <= wptr;
			seek_pos <= pair_base;
			size_set <= 1;
			commit   <= 1;
			for(i = 0; i < 10; i = i + 1) lname[i] <= name[i];
		end
	end
	else if(ev_start) begin
		blk_base <= pair_st ? hdr_end : cur_end;
		wptr     <= (pair_st ? hdr_end : cur_end) + hlen;
		nbytes   <= 0;
		xsum     <= 0;
		ovf      <= 0;
	end
	else if(ev_byte) begin
		nbytes <= nbytes + 1'd1;
		if(nbytes) xsum <= xsum ^ ev_data;
		else flag <= ev_data;
		// header blocks only: byte 1 is the file type, bytes 2..11 the name
		if(flag == 8'h00 && nbytes >= 2 && nbytes < 12) name[nbytes - 2] <= ev_data;

		// TAP images do not store the block-type byte
		if(nbytes || tape_tzx) begin
			if(wptr[17]) ovf <= 1;
			else begin
				we    <= 1;
				waddr <= wptr[16:0];
				wdata <= ev_data;
				wptr  <= wptr + 1'd1;
			end
		end
	end
	else if(ev_end && nbytes) begin
		blen <= tape_tzx ? nbytes : nbytes - 1'd1;

		if(flag == 8'h00 && nbytes == 27) begin
			// header block: refuse unless a tape and its save file are ready
			if(~tape_ready) begin
				info <= INFO_NOTAPE; info_req <= 1; pair_st <= 0;
			end
			else if(img_len > 32'h20000) begin
				info <= INFO_FULL; info_req <= 1; pair_st <= 0;   // image did not fit the buffer
			end
			else if(~sav_ok) begin
				info <= INFO_NOFILE; info_req <= 1; pair_st <= 0;
			end
			else if(ovf) begin
				info <= INFO_FULL; info_req <= 1; pair_st <= 0;
			end
			else if(xsum) begin
				info <= INFO_BADBLK; info_req <= 1; pair_st <= 0;
			end
			else begin
				pair_base <= blk_base;
				hdr_end   <= wptr;
				pair_st   <= 1;
				hw        <= hlen;
				hw_commit <= 0;
			end
		end
		else if(flag == 8'hFF && pair_st) begin
			pair_st <= 0;
			if(ovf) begin
				info <= INFO_FULL; info_req <= 1;
			end
			else if(xsum) begin
				info <= INFO_BADBLK; info_req <= 1;
			end
			else begin
				hw        <= hlen;
				hw_commit <= 1;
			end
		end
	end

	if(sd_done) begin
		info     <= INFO_SAVED;
		info_req <= 1;
	end
end

/////////////////  write the save file  /////////////////

reg [31:0] seq;
reg [17:0] plen;       // payload length
reg [17:0] nsec;       // payload sectors
reg  [1:0] sdst = 0;      // 0 idle, 1 header (writing), 2 payload, 3 header (complete)
reg  [7:0] hstate;
reg        sd_done;
reg        ack_seen;

assign busy = |sdst;
assign req  = commit | pend;
assign crc  = img_crc;
assign len  = img_len;

reg pend = 0;          // a commit is waiting for slot 1

wire [17:0] poff  = {sd_lba[8:0] - 1'd1, sd_buff_addr};  // payload byte offset
assign raddr = orig_end[16:0] + poff[16:0];

reg [7:0] hbyte;
always @(*) begin
	case(sd_buff_addr)
		0: hbyte = "J";  1: hbyte = "A";  2: hbyte = "C";  3: hbyte = "E";
		4: hbyte = "S";  5: hbyte = "A";  6: hbyte = "V";  7: hbyte = "1";
		8: hbyte = seq[7:0];   9: hbyte = seq[15:8];   10: hbyte = seq[23:16];   11: hbyte = seq[31:24];
		12: hbyte = hstate;
		13: hbyte = {7'd0, tape_tzx};
		14: hbyte = {7'd0, new_tape};
		16: hbyte = img_crc[7:0];  17: hbyte = img_crc[15:8];  18: hbyte = img_crc[23:16];  19: hbyte = img_crc[31:24];
		20: hbyte = img_len[7:0];  21: hbyte = img_len[15:8];  22: hbyte = img_len[23:16];  23: hbyte = img_len[31:24];
		24: hbyte = plen[7:0];     25: hbyte = plen[15:8];     26: hbyte = {6'd0, plen[17:16]}; 27: hbyte = 0;
		28: hbyte = lname[0]; 29: hbyte = lname[1]; 30: hbyte = lname[2]; 31: hbyte = lname[3]; 32: hbyte = lname[4];
		33: hbyte = lname[5]; 34: hbyte = lname[6]; 35: hbyte = lname[7]; 36: hbyte = lname[8]; 37: hbyte = lname[9];
		40: hbyte = new_token[7:0];  41: hbyte = new_token[15:8];  42: hbyte = new_token[23:16];  43: hbyte = new_token[31:24];
		default: hbyte = 0;
	endcase
end

assign sd_buff_din = !sd_lba ? hbyte : (poff < plen) ? rdata : 8'h00;

always @(posedge clk) begin
	sd_done <= 0;

	if(dl_start) begin
		sdst  <= 0;
		sd_wr <= 0;
		seq   <= 0;
		pend  <= 0;
	end
	else case(sdst)
		0: if((commit | pend) & sd_hold) pend <= 1;
			else if(commit | pend) begin
				pend     <= 0;
				seq      <= seq + 1'd1;
				plen     <= new_size - orig_end;
				nsec     <= (new_size - orig_end + 18'd511) >> 9;
				hstate   <= 1;
				sd_lba   <= 0;
				sd_wr    <= 1;
				ack_seen <= 0;
				sdst     <= 1;
			end

		default: begin
				if(commit) pend <= 1;   // saved again while writing: write once more after this
				if(sd_ack) begin
					sd_wr    <= 0;
					ack_seen <= 1;
				end
				else if(ack_seen) begin
					// one sector written: on to the next one
					ack_seen <= 0;
					case(sdst)
						1: begin
								sd_lba <= 1;
								sd_wr  <= 1;
								sdst   <= 2;
							end
						2: if(sd_lba[17:0] < nsec) begin
								sd_lba <= sd_lba + 1'd1;
								sd_wr  <= 1;
							end
							else begin
								hstate <= 2;
								sd_lba <= 0;
								sd_wr  <= 1;
								sdst   <= 3;
							end
						3: begin
								sdst    <= 0;
								sd_done <= 1;
							end
					endcase
				end
			end
	endcase
end

endmodule
