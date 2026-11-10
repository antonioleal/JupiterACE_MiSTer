//============================================================================
//  Jupiter Ace: wait for JupiterACE.sh to handle a save
//
//  After a snapshot (header at sector 0 of boot1.vhd) or a tape save (header
//  at sector 257) is written, the script copies it out and sets the header's
//  state byte (offset 12) to 3 (done) or 4 (failed). This module reads those
//  headers back until it sees the answer, then shows it on the OSD; with no
//  answer after about 8 s it reports that the script is not running.
//
//  Main_MiSTer caches 32 sectors of reads per disk, so each check first reads
//  the other header sector (257 sectors away) and then the wanted one: every
//  read then comes from the file.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module ack_poll
(
	input             clk,

	input             snap_done,   // pulse: snapshot written
	input             tape_done,   // pulse: tape save written

	input             other_busy,  // another module is using slot 1
	output            busy,        // reading slot 1

	output reg [31:0] lba,
	output reg        rd,
	input             ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	input             sd_buff_wr,

	// OSD messages, see the "I" line of CONF_STR
	output reg        info_req,
	output reg  [7:0] info
);

localparam INFO_TAPE_OK   = 8'd1;
localparam INFO_SNAP_OK   = 8'd6;
localparam INFO_NOSCRIPT  = 8'd11;
localparam INFO_TAPE_FAIL = 8'd13;
localparam INFO_SNAP_FAIL = 8'd14;

localparam SNAP_LBA = 32'd0;
localparam TAPE_LBA = 32'd257;

reg        pend_s = 0, pend_t = 0;  // waiting for an answer
reg  [3:0] cnt_s, cnt_t;            // checks so far
reg        tgt;                     // 0 = snapshot, 1 = tape
reg  [7:0] answer;
reg [24:0] tmr = 0;                 // ~0.65 s at 52 MHz
reg        ack_seen;

localparam S_WAIT = 2'd0, S_RD0 = 2'd1, S_RD1 = 2'd2, S_CHECK = 2'd3;
reg  [1:0] state = S_WAIT;

assign busy = (state != S_WAIT);

always @(posedge clk) begin
	info_req <= 0;

	if(snap_done) begin pend_s <= 1; cnt_s <= 0; end
	if(tape_done) begin pend_t <= 1; cnt_t <= 0; end

	case(state)
		S_WAIT:
			if(tmr) tmr <= tmr - 1'd1;
			else if((pend_s | pend_t) && !other_busy) begin
				// take turns when both are waiting
				tgt      <= pend_t & (~pend_s | ~tgt);
				lba      <= (pend_t & (~pend_s | ~tgt)) ? SNAP_LBA : TAPE_LBA;  // the other one first
				rd       <= 1;
				ack_seen <= 0;
				state    <= S_RD0;
			end

		S_RD0:
			if(ack) begin
				rd       <= 0;
				ack_seen <= 1;
			end
			else if(ack_seen) begin
				ack_seen <= 0;
				lba      <= tgt ? TAPE_LBA : SNAP_LBA;
				rd       <= 1;
				answer   <= 0;
				state    <= S_RD1;
			end

		S_RD1: begin
				if(ack & sd_buff_wr & (sd_buff_addr == 9'd12)) answer <= sd_buff_dout;
				if(ack) begin
					rd       <= 0;
					ack_seen <= 1;
				end
				else if(ack_seen) begin
					ack_seen <= 0;
					state    <= S_CHECK;
				end
			end

		S_CHECK: begin
				tmr   <= '1;
				state <= S_WAIT;
				if(!tgt && !snap_done) begin
					cnt_s <= cnt_s + 1'd1;
					if(answer == 8'd3)      begin info <= INFO_SNAP_OK;   info_req <= 1; pend_s <= 0; end
					else if(answer == 8'd4) begin info <= INFO_SNAP_FAIL; info_req <= 1; pend_s <= 0; end
					else if(cnt_s == 4'd12) begin info <= INFO_NOSCRIPT;  info_req <= 1; pend_s <= 0; end
				end
				if(tgt && !tape_done) begin
					cnt_t <= cnt_t + 1'd1;
					if(answer == 8'd3)      begin info <= INFO_TAPE_OK;   info_req <= 1; pend_t <= 0; end
					else if(answer == 8'd4) begin info <= INFO_TAPE_FAIL; info_req <= 1; pend_t <= 0; end
					else if(cnt_t == 4'd12) begin info <= INFO_NOSCRIPT;  info_req <= 1; pend_t <= 0; end
				end
			end
	endcase
end

endmodule
