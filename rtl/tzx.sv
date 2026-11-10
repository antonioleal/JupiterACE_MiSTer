//============================================================================
//  TZX player for the Jupiter Ace
//
//  Plays a .TZX image from a buffer as the EAR signal. TZX timings are in
//  ZX Spectrum T-states (3.5 MHz); the Ace CPU runs at 3.25 MHz, so every
//  duration is scaled by 13/14. `ce` must tick once per Ace CPU T-state.
//
//  Played:  0x10 standard data, 0x11 turbo data, 0x12 pure tone,
//           0x13 pulse sequence, 0x14 pure data, 0x15 direct recording,
//           0x20 pause / stop the tape, 0x24/0x25 loop, 0x2B signal level.
//  Skipped: every other block (text, info, groups, CSW, generalized data,
//           jumps and calls).
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module tzx
(
	input             clk,
	input             ce,          // one pulse per Ace CPU T-state
	input             play,        // advance the tape while high
	input             rewind,      // back to the first block
	input             seek,        // pulse: jump to the block at seek_pos
	input      [17:0] seek_pos,
	input             tape_ready,  // a tape image is in the buffer
	input      [17:0] tape_size,   // image length in bytes

	output reg [16:0] addr,        // buffer read address
	input       [7:0] din,         // buffer data (one-clock read latency)

	output reg        ear,
	output            at_end,      // no more blocks to play
	output reg        stop_req     // pulse: block 0x20 with length 0 ("stop the tape")
);

localparam S_ID    = 5'd0;
localparam S_ID2   = 5'd1;
localparam S_HDR   = 5'd2;
localparam S_HDR2  = 5'd3;
localparam S_EXEC  = 5'd4;
localparam S_P10   = 5'd5;
localparam S_PILOT = 5'd6;
localparam S_SYNC1 = 5'd7;
localparam S_SYNC2 = 5'd8;
localparam S_DNEXT = 5'd9;
localparam S_DLOAD = 5'd10;
localparam S_DBIT  = 5'd11;
localparam S_DREC  = 5'd12;
localparam S_PAUS0 = 5'd13;
localparam S_PAUS1 = 5'd14;
localparam S_TONE  = 5'd15;
localparam S_PLS0  = 5'd16;
localparam S_PLS1  = 5'd17;
localparam S_PLS2  = 5'd18;
localparam S_WAIT  = 5'd19;
localparam S_END   = 5'd20;

localparam T_MS    = 16'd3500;      // 1 ms in Spectrum T-states

reg  [4:0] state, ret;
reg [17:0] pos;                     // next unread byte of the image
reg  [7:0] rdata;
reg  [1:0] wt;

reg  [7:0] id;
reg  [4:0] hlen, hi;
reg  [7:0] hdr[20];                 // fixed part of the current block

// data block parameters (Spectrum T-states)
reg [15:0] p_pilot, p_pcount, p_sync1, p_sync2, p_zero, p_one, p_pause;
reg  [3:0] p_lastbits;
reg        p_direct;                // 0x15: bits are levels, not pulses
reg [23:0] dlen;
reg  [7:0] sbyte, plo;
reg  [3:0] nbits;
reg        half;
reg  [7:0] npulse;
reg [15:0] ms;
reg [15:0] loop_cnt;
reg [17:0] loop_pos;

// timed segment, counted in 1/13 Ace T-states: a TZX duration d lasts d*13/14 Ace T
reg        busy;
reg [20:0] cnt;
reg        seg_edge;

assign at_end = (state == S_END);

wire [15:0] h0  = {hdr[1],  hdr[0]};
wire [15:0] h2  = {hdr[3],  hdr[2]};
wire [15:0] h4  = {hdr[5],  hdr[4]};
wire [15:0] h6  = {hdr[7],  hdr[6]};
wire [15:0] h8  = {hdr[9],  hdr[8]};
wire [15:0] h10 = {hdr[11], hdr[10]};
wire [15:0] h13 = {hdr[14], hdr[13]};
wire [15:0] h2b = {hdr[3],  hdr[2]};
wire [15:0] h5  = {hdr[6],  hdr[5]};
wire [31:0] l0  = {hdr[3],  hdr[2],  hdr[1], hdr[0]};
wire [31:0] l16 = {hdr[19], hdr[18], hdr[17], hdr[16]};

// Bytes between the block ID and the block's data or payload
function [4:0] hlen_of(input [7:0] i);
	case(i)
		8'h10: hlen_of = 4;
		8'h11: hlen_of = 18;
		8'h12: hlen_of = 4;
		8'h13: hlen_of = 1;
		8'h14: hlen_of = 10;
		8'h15: hlen_of = 8;
		8'h20: hlen_of = 2;
		8'h21: hlen_of = 1;
		8'h22: hlen_of = 0;
		8'h23: hlen_of = 2;
		8'h24: hlen_of = 2;
		8'h25: hlen_of = 0;
		8'h26: hlen_of = 2;
		8'h27: hlen_of = 0;
		8'h28: hlen_of = 2;
		8'h2B: hlen_of = 5;
		8'h30: hlen_of = 1;
		8'h31: hlen_of = 2;
		8'h32: hlen_of = 2;
		8'h33: hlen_of = 1;
		8'h34: hlen_of = 8;
		8'h35: hlen_of = 20;
		8'h40: hlen_of = 4;
		8'h5A: hlen_of = 9;
		default: hlen_of = 4;  // 0x16-0x19, 0x2A and unknown blocks: 4-byte length
	endcase
endfunction

task seg(input [15:0] d, input e);
begin
	cnt      <= {d, 3'b000} + {d, 2'b00} + d;  // d * 13
	seg_edge <= e;
	busy     <= 1;
end
endtask

task rd(input [4:0] r);
begin
	addr  <= pos[16:0];
	wt    <= 2;
	ret   <= r;
	state <= S_WAIT;
end
endtask

task skip(input [31:0] n);
begin
	if({14'd0, pos} + n >= {14'd0, tape_size}) begin
		pos   <= tape_size;
		state <= S_END;
	end
	else begin
		pos   <= pos + n[17:0];
		state <= S_ID;
	end
end
endtask

always @(posedge clk) begin
	stop_req <= 0;

	if(rewind | ~tape_ready) begin
		pos      <= 18'd10;              // past the "ZXTape!\x1A" + version header
		state    <= S_ID;
		busy     <= 0;
		ear      <= 0;
		loop_cnt <= 0;
	end
	else if(seek) begin
		pos   <= seek_pos;
		state <= S_ID;
		busy  <= 0;
	end
	else if(busy) begin
		if(play & ce) begin
			if(cnt > 21'd14) cnt <= cnt - 21'd14;
			else begin
				busy <= 0;
				if(seg_edge) ear <= ~ear;
			end
		end
	end
	else begin
		case(state)
			S_WAIT:
				if(wt) wt <= wt - 1'd1;
				else begin
					rdata <= din;
					state <= ret;
				end

			S_ID:
				if(pos >= tape_size) state <= S_END;
				else rd(S_ID2);

			S_ID2: begin
					id    <= rdata;
					hlen  <= hlen_of(rdata);
					hi    <= 0;
					pos   <= pos + 1'd1;
					state <= S_HDR;
				end

			S_HDR:
				if(hi == hlen) state <= S_EXEC;
				else if(pos >= tape_size) state <= S_END;
				else rd(S_HDR2);

			S_HDR2: begin
					hdr[hi] <= rdata;
					hi      <= hi + 1'd1;
					pos     <= pos + 1'd1;
					state   <= S_HDR;
				end

			S_EXEC: begin
					p_direct <= 0;
					case(id)
						8'h10: begin // standard speed data (Spectrum ROM timings)
								p_pilot    <= 2168;
								p_sync1    <= 667;
								p_sync2    <= 735;
								p_zero     <= 855;
								p_one      <= 1710;
								p_lastbits <= 8;
								p_pause    <= h0;
								dlen       <= {8'd0, h2b};
								if(h2b) rd(S_P10);
								else state <= S_PAUS0;
							end

						8'h11: begin // turbo speed data
								p_pilot    <= h0;
								p_sync1    <= h2;
								p_sync2    <= h4;
								p_zero     <= h6;
								p_one      <= h8;
								p_pcount   <= h10;
								p_lastbits <= hdr[12][3:0];
								p_pause    <= h13;
								dlen       <= {hdr[17], hdr[16], hdr[15]};
								state      <= S_PILOT;
							end

						8'h12: begin // pure tone
								p_pilot  <= h0;
								p_pcount <= h2;
								state    <= S_TONE;
							end

						8'h13: begin // pulse sequence
								npulse <= hdr[0];
								state  <= S_PLS0;
							end

						8'h14: begin // pure data
								p_pcount   <= 0;
								p_sync1    <= 0;
								p_sync2    <= 0;
								p_zero     <= h0;
								p_one      <= h2;
								p_lastbits <= hdr[4][3:0];
								p_pause    <= h5;
								dlen       <= {hdr[9], hdr[8], hdr[7]};
								state      <= S_PILOT;
							end

						8'h15: begin // direct recording: p_zero holds T-states per sample
								p_zero     <= h0;
								p_pause    <= h2;
								p_lastbits <= hdr[4][3:0];
								dlen       <= {hdr[7], hdr[6], hdr[5]};
								p_direct   <= 1;
								state      <= S_DNEXT;
							end

						8'h20: begin // pause, or stop the tape
								p_pause <= h0;
								if(h0) state <= S_PAUS0;
								else begin
									stop_req <= 1;
									state    <= S_ID;
								end
							end

						8'h24: begin // loop start
								loop_cnt <= h0;
								loop_pos <= pos;
								state    <= S_ID;
							end

						8'h25: begin // loop end
								if(loop_cnt > 1) begin
									loop_cnt <= loop_cnt - 1'd1;
									pos      <= loop_pos;
								end
								else loop_cnt <= 0;
								state <= S_ID;
							end

						8'h2B: begin // set signal level
								ear   <= hdr[4][0];
								state <= S_ID;
							end

						8'h21, 8'h30: skip(hdr[0]);
						8'h31:        skip(hdr[1]);
						8'h26:        skip({h0, 1'b0});
						8'h28, 8'h32: skip(h0);
						8'h33:        skip({hdr[0], 1'b0} + hdr[0]);
						8'h35:        skip(l16);
						8'h40:        skip({hdr[3], hdr[2], hdr[1]});
						8'h22, 8'h23, 8'h27, 8'h34, 8'h5A: state <= S_ID;
						default:      skip(l0);
					endcase
				end

			// 0x10: header blocks (flag < 128) get the long pilot
			S_P10: begin
					p_pcount <= rdata[7] ? 16'd3223 : 16'd8063;
					state    <= S_PILOT;
				end

			S_PILOT:
				if(p_pcount) begin
					seg(p_pilot, 1);
					p_pcount <= p_pcount - 1'd1;
				end
				else state <= S_SYNC1;

			S_SYNC1: begin
					if(p_sync1) seg(p_sync1, 1);
					state <= S_SYNC2;
				end

			S_SYNC2: begin
					if(p_sync2) seg(p_sync2, 1);
					state <= S_DNEXT;
				end

			S_DNEXT:
				if(!dlen) state <= S_PAUS0;
				else if(pos >= tape_size) state <= S_END;
				else rd(S_DLOAD);

			S_DLOAD: begin
					sbyte <= rdata;
					pos   <= pos + 1'd1;
					nbits <= (dlen == 1 && p_lastbits && p_lastbits < 8) ? p_lastbits : 4'd8;
					dlen  <= dlen - 1'd1;
					half  <= 0;
					state <= p_direct ? S_DREC : S_DBIT;
				end

			S_DBIT:
				if(!nbits) state <= S_DNEXT;
				else begin
					seg(sbyte[7] ? p_one : p_zero, 1);
					half <= ~half;
					if(half) begin
						sbyte <= {sbyte[6:0], 1'b0};
						nbits <= nbits - 1'd1;
					end
				end

			S_DREC:
				if(!nbits) state <= S_DNEXT;
				else begin
					ear   <= sbyte[7];
					seg(p_zero, 0);
					sbyte <= {sbyte[6:0], 1'b0};
					nbits <= nbits - 1'd1;
				end

			// pause: the first millisecond keeps the last level, then the signal goes low
			S_PAUS0:
				if(!p_pause) state <= S_ID;
				else begin
					seg(T_MS, 0);
					ms    <= p_pause - 1'd1;
					state <= S_PAUS1;
				end

			S_PAUS1: begin
					ear <= 0;
					if(!ms) state <= S_ID;
					else begin
						seg(T_MS, 0);
						ms <= ms - 1'd1;
					end
				end

			S_TONE:
				if(p_pcount) begin
					seg(p_pilot, 1);
					p_pcount <= p_pcount - 1'd1;
				end
				else state <= S_ID;

			S_PLS0:
				if(!npulse) state <= S_ID;
				else if(pos + 18'd1 >= tape_size) state <= S_END;
				else rd(S_PLS1);

			S_PLS1: begin
					plo   <= rdata;
					pos   <= pos + 1'd1;
					addr  <= pos[16:0] + 1'd1;
					wt    <= 2;
					ret   <= S_PLS2;
					state <= S_WAIT;
				end

			S_PLS2: begin
					seg({rdata, plo}, 1);
					pos    <= pos + 1'd1;
					npulse <= npulse - 1'd1;
					state  <= S_PLS0;
				end

			S_END: ;
		endcase
	end
end

endmodule
