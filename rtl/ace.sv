//============================================================================
//  Jupiter Ace main logic
//  Copyright (C) 2018 Sorgelig
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

module ace
(
	input        clk,
	input        ce_pix,
	input        ce_cpu,
	input        no_wait,
	input        reset,

	output [7:0] kbd_row,
	input  [4:0] kbd_col,
	output       video_out,
	output       hsync,
	output       vsync,
	output       hblank,
	output       vblank,
	output reg   mic,
	output reg   spk,

	input        tape_in,   // EAR: read on port FE bit 5
	output       tape_load, // CPU is running the ROM LOAD routine
	output       tape_save, // CPU is running the ROM SAVE routine
	output reg [7:0] name0, // first character of the tape name LOAD/SAVE was given

	// writes to the system variables 3C00-3C3F (by the CPU or the snapshot loader)
	output       sv_we,
	output [5:0] sv_addr,
	output [7:0] sv_data,

	input        int_fast,   // spooling: frame interrupt from int_fast_n, not vsync
	input        int_fast_n,

	// memory: 0 = 3K, 1 = 19K, 2 = 35K, 3 = 51K, 4 = 99K (96K RAM pack)
	input  [2:0] mem_rank,
	input        mem_cold,     // pulse: new memory, 96K page mapping back to the start
	input        ld_phys,      // the loader writes physical page 1 (else 0)
	input        pg_set,       // pulse: loading ended, the page in use is ...
	input        pg_set_page,  // ... this one, kept in physical page 0
	input        snap_other,   // the snapshot reads the other page
	output       page,         // the 96K pack's page in use

	input        loader_en,
	input [15:0] loader_addr,
	input  [7:0] loader_data,
	input        loader_wr,

	// snapshot save: stop the CPU, then read RAM
	input          snap_hold,  // stop at the next instruction boundary
	output         snap_held,  // stopped; cpu_reg is the complete CPU state
	output         cpu_halted, // stopped inside HALT (PC is past the HALT)
	output [211:0] cpu_reg,
	input          snap_en,    // snap_addr drives the RAM (only while held)
	input   [15:0] snap_addr,
	output   [7:0] snap_data   // one clock after snap_addr
);

assign kbd_row = cpu_addr[15:8];

wire [15:0]	addr   = loader_en ? loader_addr : snap_en ? snap_addr : cpu_addr;
wire  [7:0] data   = loader_en ? loader_data : cpu_dout;
wire        ram_we = loader_en ? loader_wr   : snap_en ? 1'b0 : ~wr_n;
wire        mem_on = ~mreq_n | loader_en | snap_en;

wire rom_enable  = mem_on && (addr[15:13] == 0);       // 0000 - 1FFF 8KB
wire sram_enable = mem_on && (addr[15:11] == 'b00100); // 2000 - 27FF 1KB * 2
wire cram_enable = mem_on && (addr[15:11] == 'b00101); // 2800 - 2FFF 1KB * 2
wire uram_enable = mem_on && (addr[15:12] == 'b0011);  // 3000 - 3FFF 1KB * 4

assign sv_we   = ram_we & mem_on & (addr[15:6] == 10'b0011_1100_00);
assign sv_addr = addr[5:0];
assign sv_data = data;
// RAM pack at 4000-FFFF: 16K, 32K or 48K, or the 96K pack (Edwin Blink's
// design): two 48K pages. Missing RAM ignores writes and reads FF, so the
// ROM's RAM test at power-on finds the size.
//
// The 96K pack's page is bit 7 of the Z80's R register, latched in every
// refresh cycle: only LD R,A changes it, and the new page takes over at the
// refresh after the next opcode fetch (or an interrupt acknowledge). A reset
// goes back to page 0. The pages are kept in two physical RAMs; swap says which
// one holds page 0, so a snapshot (whose page in use is only known after it
// has been loaded into physical page 0) needs no copying.
reg  pg = 0, swap = 0;
wire rfsh_n;
assign page = pg;
always @(posedge clk) begin
	if(mem_cold) begin pg <= 0; swap <= 0; end
	else if(pg_set) begin pg <= pg_set_page; swap <= pg_set_page; end
	else if(reset & ~loader_en) pg <= 0;
	else if(~rfsh_n) pg <= REG_out[47];
end

wire pg_phys  = (mem_rank == 3'd4) & (pg ^ swap);
wire phys     = loader_en ? ld_phys : (snap_en & snap_other) ? ~pg_phys : pg_phys;
wire pack_on  = (addr[15:14] == 2'b01) ? (mem_rank >= 3'd1) :
                (addr[15:14] == 2'b10) ? (mem_rank >= 3'd2) :
                (addr[15:14] == 2'b11) ? (mem_rank >= 3'd3) : 1'b0;
wire xram_enable  = mem_on && pack_on && (addr[15:14] == 'b01) && !phys;   // 4000 - 7FFF 16KB
wire eram_enable  = mem_on && pack_on && (addr[15])            && !phys;   // 8000 - FFFF 32KB
wire xram1_enable = mem_on && pack_on && (addr[15:14] == 'b01) &&  phys;   // the 96K pack's
wire eram1_enable = mem_on && pack_on && (addr[15])            &&  phys;   // second page

wire wait_n = no_wait | ~(sram_enable | cram_enable) | hblank | vblank | ~addr[10]; // 2400 - 27FF, 2C00 - 2FFF

always @(posedge clk) begin
	if (~iorq_n & ~cpu_addr[0]) begin
		if (~rd_n) spk <= 0;
		if (~wr_n) {spk,mic} <= {1'b1,cpu_dout[3]};
	end
end

wire [7:0] io_dout = {8{iorq_n|rd_n}} | (~cpu_addr[0] ? {2'b11, tape_in, kbd_col} : (sram_data | cram_data));

// Instruction fetch inside the ROM tape loader (0x18A7-0x192C), used for tape autoplay
assign tape_load = ~m1_n & ~mreq_n & (cpu_addr >= 16'h18A7) & (cpu_addr <= 16'h192C);

// The ROM parses the tape name into 2702 (the same RAM as 2302, where the tape
// header is built): remember its first character, 00 or space when blank
always @(posedge clk) if(~mreq_n & ~wr_n & ((cpu_addr & 16'hFBFF) == 16'h2302)) name0 <= cpu_dout;

// Instruction fetch inside the ROM tape saver (0x1820-0x18A6), used by the recorder
assign tape_save = ~m1_n & ~mreq_n & (cpu_addr >= 16'h1820) & (cpu_addr <= 16'h18A6);

wire [9:0] sram_addr;
wire [7:0] sram_data;
wire [7:0] sram_dout;
dpram #(10) sram
(
	.clock(clk),
	.address_a(addr[9:0]),
	.data_a(data),
	.wren_a(ram_we & sram_enable),
	.oe_a_n(~sram_enable),
	.q_a(sram_dout),
	.address_b(sram_addr),
	.q_b(sram_data)
);

wire [9:0] cram_addr;
wire [7:0] cram_data;
wire [7:0] cram_q;      // the CPU cannot read the character RAM; the snapshot can
dpram #(10) cram
(
	.clock(clk),
	.address_a(addr[9:0]),
	.data_a(data),
	.wren_a(ram_we & cram_enable),
	.oe_a_n(1'b0),
	.q_a(cram_q),
	.address_b(cram_addr),
	.q_b(cram_data)
);

wire [7:0] uram_dout;
dpram #(10) uram
(
	.clock(clk),
	.address_a(addr[9:0]),
	.data_a(data),
	.wren_a(ram_we & uram_enable),
	.oe_a_n(~uram_enable),
	.q_a(uram_dout)
);

wire [7:0] xram_dout;
dpram #(14) xram
(
	.clock(clk),
	.address_a(addr[13:0]),
	.data_a(data),
	.wren_a(ram_we & xram_enable),
	.oe_a_n(~xram_enable),
	.q_a(xram_dout)
);

wire [7:0] eram_dout;
dpram #(15) eram
(
	.clock(clk),
	.address_a(addr[14:0]),
	.data_a(data),
	.wren_a(ram_we & eram_enable),
	.oe_a_n(~eram_enable),
	.q_a(eram_dout)
);

wire [7:0] xram1_dout;
dpram #(14) xram1
(
	.clock(clk),
	.address_a(addr[13:0]),
	.data_a(data),
	.wren_a(ram_we & xram1_enable),
	.oe_a_n(~xram1_enable),
	.q_a(xram1_dout)
);

wire [7:0] eram1_dout;
dpram #(15) eram1
(
	.clock(clk),
	.address_a(addr[14:0]),
	.data_a(data),
	.wren_a(ram_we & eram1_enable),
	.oe_a_n(~eram1_enable),
	.q_a(eram1_dout)
);

wire [7:0] pack_dout = xram_dout & eram_dout & xram1_dout & eram1_dout;

wire [7:0] rom_dout;
dpram #(.ADDRWIDTH(13), .MEM_INIT_FILE("rtl/ace.mif")) rom
(
	.clock(clk),
	.address_a(snap_en ? snap_addr[12:0] : cpu_addr[12:0]),
	.oe_a_n(~rom_enable),
	.q_a(rom_dout)
);

// snapshot reads: the character RAM, or the other RAMs and the ROM
reg snap_cram;
always @(posedge clk) snap_cram <= (snap_addr[15:11] == 'b00101);
assign snap_data = snap_cram ? cram_q : (rom_dout & sram_dout & uram_dout & pack_dout);

wire  [7:0] cpu_dout;
wire [15:0] cpu_addr;
wire        iorq_n, mreq_n, rd_n, wr_n, int_n, m1_n, halt_n;
wire [211:0] REG_out;
assign cpu_halted = ~halt_n;
assign cpu_reg    = REG_out;
T80pa cpu
(
	.RESET_n(~(reset | loader_reset)),
	.CLK(clk),
	.CEN_p(ce_cpu),

	.WAIT_n(wait_n),
	.INT_n(int_fast ? int_fast_n : vsync),
	.M1_n(m1_n),
	.HALT_n(halt_n),
	.RFSH_n(rfsh_n),
	.MREQ_n(mreq_n),
	.IORQ_n(iorq_n),
	.RD_n(rd_n),
	.WR_n(wr_n),
	.A(cpu_addr),
	.DI(rom_dout & sram_dout & uram_dout & pack_dout & io_dout),
	.DO(cpu_dout),
	.DIRSet(|regset),
	.DIR(REG),
	.REG(REG_out),
	.HOLD(snap_hold),
	.HELD(snap_held)
);

reg  [211:0] REG;  // IFF2, IFF1, IM, IY, HL', DE', BC', IX, HL, DE, BC, PC, SP, R, I, F', A', F, A
reg    [1:0] regset = 0;
reg          loader_reset;
always @(posedge clk) begin
	reg old_loader;
	reg old_vsync;
	
	old_vsync <= vsync;

	if(loader_en) begin
		loader_reset <= 1;
		regset <= 2'b11;
		if(loader_wr && (loader_addr[15:8] == 8'h21) && !loader_addr[7]) begin
			case(loader_addr[6:0])
				'h00: REG[15:8]    <= loader_data; //f
				'h01: REG[7:0]     <= loader_data; //a
				'h04: REG[87:80]   <= loader_data; //c
				'h05: REG[95:88]   <= loader_data; //b
				'h08: REG[103:96]  <= loader_data; //e
				'h09: REG[111:104] <= loader_data; //d
				'h0C: REG[119:112] <= loader_data; //l
				'h0D: REG[127:120] <= loader_data; //h
				'h10: REG[135:128] <= loader_data; //xl
				'h11: REG[143:136] <= loader_data; //xh
				'h14: REG[199:192] <= loader_data; //yl
				'h15: REG[207:200] <= loader_data; //yh
				'h18: REG[55:48]   <= loader_data; //spl
				'h19: REG[63:56]   <= loader_data; //sph
				'h1C: REG[71:64]   <= loader_data; //pcl
				'h1D: REG[79:72]   <= loader_data; //pch
				'h20: REG[31:24]   <= loader_data; //f'
				'h21: REG[23:16]   <= loader_data; //a'
				'h24: REG[151:144] <= loader_data; //c'
				'h25: REG[159:152] <= loader_data; //b' //EightyOne wrongly restores it to B register
				'h28: REG[167:160] <= loader_data; //e'
				'h29: REG[175:168] <= loader_data; //d'
				'h2C: REG[183:176] <= loader_data; //l'
				'h2D: REG[191:184] <= loader_data; //h'
				'h30: REG[209:208] <= loader_data[1:0]; //im
				'h34: REG[210]     <= loader_data[0];   //iff1
				'h38: REG[211]     <= loader_data[0];   //iff2
				'h3C: REG[39:32]   <= loader_data; //i
				'h40: REG[47:40]   <= loader_data; //r
			endcase
		end
	end
	else begin
		if(~old_vsync & vsync) loader_reset <= 0;
		if(~loader_reset && regset) begin
			regset <= regset - 1'd1;
			// loader_addr wraps to 0 after a dump that reaches FFFF: SP is inside it
			if(loader_addr && REG[63:48] > loader_addr) begin
				REG[63:48] <= 16'hFFFE; // bug in dump!
			end
		end
	end
end

video video (.*);

endmodule
