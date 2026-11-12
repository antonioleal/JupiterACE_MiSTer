//============================================================================
//  Jupiter Ace / Jupiter II video
//  Copyright (C) 2018 Sorgelig
//
//  Jupiter Ace: 312 lines of 416 pixels (208 T-states), 50 Hz; the 256x192
//  picture only, vsync (the Z80's INT) for 8 lines from pixel 308 of line 248.
//
//  Jupiter II (https://github.com/ricaflops/Jupiter-II): 262 lines, 59.64 Hz;
//  vsync for 4 lines from the start of line 224 (J-II_TIME.PLD). The picture
//  is shown with a 32-pixel border (320x240). With the Expansion board each
//  character cell has an attribute byte, PAPER (bits 7-4) and INK (bits 3-0),
//  and the border has its own colour; colours are IRGB, each channel off, half
//  or full (the colour board adds the colour and intensity lines). Without it
//  the picture is white on black. The inverse video jumper swaps the two.
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

module video
(
	input         clk,
	input         ce_pix,

	input         j2,          // Jupiter II timing and border
	input         colour,      // the Expansion's colour
	input         inverse,     // the Jupiter II's inverse video jumper

	output  [9:0] sram_addr,
	input   [7:0] sram_data,
	output  [9:0] cram_addr,
	input   [7:0] cram_data,
	input   [7:0] attr_data,   // attribute of the cell at sram_addr
	input   [3:0] border,

	output  [3:0] r,
	output  [3:0] g,
	output  [3:0] b,
	output reg    hsync,
	output reg    vsync,
	output reg    hblank,
	output reg    vblank
);

assign sram_addr = {vcnt[7:3], hcnt[7:3]};
assign cram_addr = {sram_data[6:0], vcnt[2:0]};

reg [8:0] hcnt;
reg [8:0] vcnt;
reg [7:0] pix;
reg       inv;
reg [7:0] attr;
reg       pic;              // the 8 pixels in pix are in the picture

wire hpic = (hcnt < 9'd256);
wire vpic = (vcnt < 9'd192);

// visible area: the picture, and for the Jupiter II a 32-pixel border
wire hvis = j2 ? (hcnt >= 9'd384 || hcnt < 9'd288) : hpic;
wire vvis = j2 ? (vcnt >= 9'd238 || vcnt < 9'd216) : vpic;

always @(posedge clk) begin
	if(ce_pix) begin
		if (hcnt != 415) hcnt <= hcnt + 1'd1;
		else begin
			hcnt <= 0;
			if (vcnt < (j2 ? 9'd261 : 9'd311)) vcnt <= vcnt + 1'd1;
			else vcnt <= 0;
		end

		if (hcnt == 308) hsync <= 0;
		if (hcnt == 340) hsync <= 1;
		if (j2) begin
			if (hcnt == 0 && vcnt == 224) vsync <= 0;
			if (hcnt == 0 && vcnt == 228) vsync <= 1;
		end
		else if (hcnt == 308) begin
			if (vcnt == 248) vsync <= 0;
			if (vcnt == 256) vsync <= 1;
		end

		hblank <= ~hvis;
		vblank <= ~vvis;

		pix <= {pix[6:0], 1'b0};
		if (!hcnt[2:0]) begin
			pic  <= vpic & hpic;
			inv  <= vpic & hpic & sram_data[7];
			attr <= attr_data;
			if (vpic && hpic) pix <= cram_data;
		end
	end
end

// the pixel: INK where it is set (after inverse characters and the jumper), PAPER elsewhere
wire       on  = pix[7] ^ inv ^ (j2 & inverse);
wire [3:0] c   = !pic   ? (colour ? border : 4'd0) :
                 colour ? (on ? attr[3:0] : attr[7:4]) :
                 on     ? 4'd15 : 4'd0;

// IRGB: each channel off, half or full
wire [1:0] lr  = c[2] + c[3];
wire [1:0] lg  = c[1] + c[3];
wire [1:0] lb  = c[0] + c[3];
assign r = (lr == 2) ? 4'd15 : (lr == 1) ? 4'd8 : 4'd0;
assign g = (lg == 2) ? 4'd15 : (lg == 1) ? 4'd8 : 4'd0;
assign b = (lb == 2) ? 4'd15 : (lb == 1) ? 4'd8 : 4'd0;

endmodule
