//============================================================================
//  Jupiter Ace .TAP player
//
//  Plays a Jupiter Ace .TAP image from a buffer as the EAR signal the ROM
//  LOAD routine (0x18A7) expects.
//
//  .TAP layout: repeated [length lo, length hi, data...]. The length includes
//  the trailing XOR checksum. The block-type byte sent on tape (0x00 header,
//  0xFF data) is not stored; a block of length 26 (0x1A) is a header.
//
//  Timings are in Z80 T-states, taken from the Ace ROM SAVE routine (0x1820):
//    pilot  : 8192 (header) / 1024 (data) half-waves of 2011 T
//    sync   : 601 T, then 791 T
//    bit 0  : two half-waves of 801 T
//    bit 1  : two half-waves of 1591 T
//    end    : one final edge 917 T after the last bit
//  `ce` must tick once per CPU T-state, so the tape keeps step with turbo.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module tape
(
	input             clk,
	input             ce,          // one pulse per CPU T-state
	input             play,        // advance the tape while high
	input             rewind,      // back to the start of the tape
	input             seek,        // pulse: jump to the block at seek_pos
	input      [17:0] seek_pos,
	input             tape_ready,  // a tape image is in the buffer
	input      [17:0] tape_size,   // image length in bytes

	output reg [16:0] addr,        // buffer read address
	input       [7:0] din,         // buffer data (one-clock read latency)

	output reg        ear,
	output            at_end       // no more blocks to play
);

localparam T_PILOT = 22'd2011;
localparam T_SYNC1 = 22'd601;
localparam T_SYNC2 = 22'd791;
localparam T_BIT0  = 22'd801;
localparam T_BIT1  = 22'd1591;
localparam T_END   = 22'd917;
localparam T_PAUSE = 22'd3250000;  // 1 s of silence after each block

localparam S_NEXT   = 4'd0;
localparam S_LEN0   = 4'd1;
localparam S_LEN1   = 4'd2;
localparam S_BLK    = 4'd3;
localparam S_PILOT  = 4'd4;
localparam S_SYNC1  = 4'd5;
localparam S_SYNC2  = 4'd6;
localparam S_BIT    = 4'd7;
localparam S_FETCH0 = 4'd8;
localparam S_FETCH1 = 4'd9;
localparam S_ENDM   = 4'd10;
localparam S_PAUSE  = 4'd11;

reg  [3:0] state;
reg [17:0] pos;      // next unread byte of the image
reg [15:0] len;      // bytes of the current block still to fetch
reg [12:0] pcnt;     // pilot half-waves left
reg  [7:0] sbyte;    // byte being shifted out, MSB first
reg  [2:0] bitn;
reg        half;
reg  [1:0] wt;       // buffer read wait

reg        busy;     // a timed segment is running
reg [21:0] cnt;
reg        seg_edge; // toggle EAR when the segment ends

assign at_end = (state == S_NEXT) && (pos + 18'd1 >= tape_size);

// Start a timed segment of `dur` T-states, optionally ending with an edge.
task seg(input [21:0] dur, input e);
begin
	cnt      <= dur - 1'd1;
	seg_edge <= e;
	busy     <= 1;
end
endtask

always @(posedge clk) begin
	if(rewind | ~tape_ready) begin
		pos   <= 0;
		state <= S_NEXT;
		busy  <= 0;
		ear   <= 0;
	end
	else if(seek) begin
		pos   <= seek_pos;
		state <= S_NEXT;
		busy  <= 0;
	end
	else if(busy) begin
		if(play & ce) begin
			if(cnt) cnt <= cnt - 1'd1;
			else begin
				busy <= 0;
				if(seg_edge) ear <= ~ear;
			end
		end
	end
	else begin
		case(state)
			S_NEXT:
				if(pos + 18'd1 < tape_size) begin
					addr  <= pos[16:0];
					wt    <= 2;
					state <= S_LEN0;
				end

			S_LEN0:
				if(wt) wt <= wt - 1'd1;
				else begin
					len[7:0] <= din;
					addr     <= pos[16:0] + 1'd1;
					wt       <= 2;
					state    <= S_LEN1;
				end

			S_LEN1:
				if(wt) wt <= wt - 1'd1;
				else begin
					len[15:8] <= din;
					pos       <= pos + 18'd2;
					state     <= S_BLK;
				end

			S_BLK:
				if(!len) state <= S_NEXT;                                  // empty block: skip
				else if({2'b00, len} > tape_size - pos) begin pos <= tape_size; state <= S_NEXT; end // truncated image
				else begin
					pcnt  <= (len == 16'd26) ? 13'd8191 : 13'd1023;
					sbyte <= (len == 16'd26) ? 8'h00 : 8'hFF;             // block-type byte
					state <= S_PILOT;
				end

			S_PILOT: begin
					seg(T_PILOT, 1);
					if(pcnt) pcnt <= pcnt - 1'd1;
					else state <= S_SYNC1;
				end

			S_SYNC1: begin
					seg(T_SYNC1, 1);
					state <= S_SYNC2;
				end

			S_SYNC2: begin
					seg(T_SYNC2, 1);
					bitn  <= 0;
					half  <= 0;
					state <= S_BIT;
				end

			S_BIT: begin
					seg(sbyte[7] ? T_BIT1 : T_BIT0, 1);
					half <= ~half;
					if(half) begin
						sbyte <= {sbyte[6:0], 1'b0};
						bitn  <= bitn + 1'd1;
						if(bitn == 7) state <= len ? S_FETCH0 : S_ENDM;
					end
				end

			S_FETCH0: begin
					addr  <= pos[16:0];
					wt    <= 2;
					state <= S_FETCH1;
				end

			S_FETCH1:
				if(wt) wt <= wt - 1'd1;
				else begin
					sbyte <= din;
					pos   <= pos + 1'd1;
					len   <= len - 1'd1;
					state <= S_BIT;
				end

			S_ENDM: begin
					seg(T_END, 1);
					state <= S_PAUSE;
				end

			S_PAUSE: begin
					seg(T_PAUSE, 0);
					state <= S_NEXT;
				end
		endcase
	end
end

endmodule
