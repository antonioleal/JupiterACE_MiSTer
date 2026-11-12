//============================================================================
//  AY-3-8910 sound generator (the Jupiter II Expansion's sound chip)
//
//  The registers are kept by the CPU interface (ace.sv); this makes the sound:
//    R0-R5   tone periods of channels A, B, C (12 bits)
//    R6      noise period (5 bits)
//    R7      mixer: bits 0-2 tone off for A, B, C; bits 3-5 noise off
//    R8-R10  volumes: bits 0-3 level, bit 4 use the envelope
//    R11-R12 envelope period (16 bits), R13 envelope shape (a write restarts it)
//
//  The chip's clock is 3.25 MHz (ce_ay), divided by 8 inside: a tone's square
//  wave has a period of 16 x its period register (203125 / period Hz), the
//  noise shift register (17 bits, bit 0 xor bit 3) shifts every 16 x the noise
//  period, and the envelope takes a step every 16 x its period. A period of 0
//  counts as 1. Volumes follow the chip's logarithmic DAC.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module ay
(
	input             clk,
	input             ce_ay,       // 3.25 MHz
	input             reset,

	input       [7:0] r0, r1, r2, r3, r4, r5, r6, r7,
	input       [7:0] r8, r9, r10, r11, r12, r13,
	input             env_restart, // pulse: R13 written

	output reg [13:0] ch_a,        // channel outputs (0 - 12287)
	output reg [13:0] ch_b,
	output reg [13:0] ch_c
);

reg [2:0] pre;                 // /8
wire tick = ce_ay && pre == 3'd0;
always @(posedge clk) if(ce_ay) pre <= pre + 1'd1;

/////////////////  tones  /////////////////

wire [11:0] tp_a = {r1[3:0], r0};
wire [11:0] tp_b = {r3[3:0], r2};
wire [11:0] tp_c = {r5[3:0], r4};

reg [11:0] cnt_a, cnt_b, cnt_c;
reg        tone_a, tone_b, tone_c;

always @(posedge clk) begin
	if(reset) begin
		cnt_a <= 0; cnt_b <= 0; cnt_c <= 0;
		tone_a <= 0; tone_b <= 0; tone_c <= 0;
	end
	else if(tick) begin
		if(cnt_a + 1'd1 >= tp_a) begin cnt_a <= 0; tone_a <= ~tone_a; end else cnt_a <= cnt_a + 1'd1;
		if(cnt_b + 1'd1 >= tp_b) begin cnt_b <= 0; tone_b <= ~tone_b; end else cnt_b <= cnt_b + 1'd1;
		if(cnt_c + 1'd1 >= tp_c) begin cnt_c <= 0; tone_c <= ~tone_c; end else cnt_c <= cnt_c + 1'd1;
	end
end

/////////////////  noise  /////////////////

reg  [4:0] cnt_n;
reg        npre;
reg [16:0] lfsr = 17'd1;
wire       noise = lfsr[0];

always @(posedge clk) begin
	if(reset) begin
		cnt_n <= 0;
		npre  <= 0;
		lfsr  <= 17'd1;
	end
	else if(tick) begin
		if(cnt_n + 1'd1 >= r6[4:0]) begin
			cnt_n <= 0;
			npre  <= ~npre;
			if(npre) lfsr <= {lfsr[0] ^ lfsr[3], lfsr[16:1]};
		end
		else cnt_n <= cnt_n + 1'd1;
	end
end

/////////////////  envelope  /////////////////

// R13: bit 3 continue, bit 2 attack, bit 1 alternate, bit 0 hold
wire [15:0] ep = {r12, r11};
reg  [16:0] cnt_e;
reg   [3:0] step;
reg         att, holding;
wire  [3:0] env = att ? step : ~step;

always @(posedge clk) begin
	if(reset | env_restart) begin
		cnt_e   <= 0;
		step    <= 0;
		att     <= r13[2];
		holding <= 0;
	end
	else if(tick && !holding) begin
		if(cnt_e + 1'd1 >= {ep, 1'b0}) begin
			cnt_e <= 0;
			if(step != 4'd15) step <= step + 1'd1;
			else if(!r13[3]) begin            // one cycle, then 0
				att     <= 0;
				holding <= 1;
			end
			else if(r13[0]) begin             // hold: the last value, or its opposite
				if(r13[1]) att <= ~att;
				holding <= 1;
			end
			else begin                         // repeat, or alternate
				if(r13[1]) att <= ~att;
				step <= 0;
			end
		end
		else cnt_e <= cnt_e + 1'd1;
	end
end
// (holding with att = 0 and step = 15 gives 0; with att = 1, 15)

/////////////////  mixer and volume  /////////////////

// the AY-3-8910's DAC (normalised levels x 12287)
function [13:0] dac(input [3:0] v);
	case(v)
		0:  dac = 14'd0;     1:  dac = 14'd130;   2:  dac = 14'd184;   3:  dac = 14'd273;
		4:  dac = 14'd393;   5:  dac = 14'd573;   6:  dac = 14'd817;   7:  dac = 14'd1277;
		8:  dac = 14'd1520;  9:  dac = 14'd2440;  10: dac = 14'd3444;  11: dac = 14'd4359;
		12: dac = 14'd5777;  13: dac = 14'd7409;  14: dac = 14'd9252;  default: dac = 14'd12287;
	endcase
endfunction

wire on_a = (tone_a | r7[0]) & (noise | r7[3]);
wire on_b = (tone_b | r7[1]) & (noise | r7[4]);
wire on_c = (tone_c | r7[2]) & (noise | r7[5]);

wire [3:0] vol_a = r8[4]  ? env : r8[3:0];
wire [3:0] vol_b = r9[4]  ? env : r9[3:0];
wire [3:0] vol_c = r10[4] ? env : r10[3:0];

always @(posedge clk) begin
	ch_a <= on_a ? dac(vol_a) : 14'd0;
	ch_b <= on_b ? dac(vol_b) : 14'd0;
	ch_c <= on_c ? dac(vol_c) : 14'd0;
end

endmodule
