//============================================================================
//  Jupiter Ace / Jupiter II main logic
//  Copyright (C) 2018 Sorgelig
//
//  The machine (mach): 0 = Jupiter Ace, 1 = Jupiter II, 2 = Jupiter II with its
//  Expansion board, as in Jupiter-IIb (https://github.com/antonioleal/Jupiter-IIb).
//  The Jupiter II (https://github.com/ricaflops/Jupiter-II) has 2K of program
//  RAM at 3000-37FF (seen again at 3800-3FFF) and two 1K pages of screen and of
//  character set RAM (page 1 without the Expansion). The Expansion board
//  (https://github.com/ricaflops/Jupiter-II-Expansion) adds:
//    - an AY-3-8910 at odd ports 1111xxx1b: FDh selects a register, FFh reads /
//      writes it. Its port A (register 14, an output when register 7 bit 6 is
//      set, else FFh) holds PAPER (bits 7-4) and INK (bits 3-0); port B
//      (register 15, register 7 bit 7) the BORDER colour (bits 7-4), character
//      set page (bit 3), screen page (bit 2) and memory page (bits 1-0). A reset
//      clears the registers: page 3, character set 1, screen 1.
//    - colour: a 2K attribute RAM, one byte per cell of each screen page,
//      written with port A whenever the CPU writes the screen RAM.
//    - 128K of RAM: 4000-7FFF always the same 16K; 8000-FFFF memory page 0, 1
//      or 2 (32K each), or page 3: 16K of RAM and the Expansion ROM at C000.
//    - the boot ROM's patched copy: IM 1 / JR 009Bh at 008Eh becomes JP C000h /
//      NOP, so the Expansion ROM starts (it does the IM 1 itself).
//  The sound chip's sound is made by ay.sv (channels A, B, C out). The 16C450
//  UART (uart16450.sv) is at odd ports 1110rrr1b (E1h - EFh).
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

	input  [1:0] mach,       // 0 Jupiter Ace, 1 Jupiter II, 2 Jupiter II + Expansion
	input        inverse,    // the Jupiter II's inverse video jumper

	output [7:0] kbd_row,
	input  [4:0] kbd_col,
	output [13:0] ay_a,      // the Expansion's sound chip: channel outputs
	output [13:0] ay_b,
	output [13:0] ay_c,
	input        uart_rxd,   // the Expansion's serial port (16C450): line in
	output       uart_txd,   // ... and out (idle high)
	output [3:0] vid_r,
	output [3:0] vid_g,
	output [3:0] vid_b,
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

	// the Jupiter II Expansion's state, for snapshots: the loader or the snapshot
	// reads / writes it through a "space" (0 = memory as the Z80 sees it):
	//   1 screen page xs_pg, 2 character set page xs_pg, 3 attribute page xs_pg
	//   (address bits 9-0), 4 memory page xs_pg (8000-FFFF), 5 nothing
	input  [2:0] xs_space,
	input  [1:0] xs_pg,
	input        xs_swap_set,  // pulse: the shown screen / character set pages are
	input        xs_sswap,     // ... in the other RAM (the snapshot's image was
	input        xs_cswap,     // ... loaded into page 1)
	input        ay_ld,        // pulse: the loader sets sound chip register ay_ld_idx
	input  [4:0] ay_ld_idx,    // (16: the register selected)
	input        ay_mpage0,    // pulse: memory page 0, as an OUT to port B would
	output [7:0] ay_regs[17],  // the sound chip's registers, and the one selected
	output [7:0] port_b_out,
	output       page,         // the 96K pack's page in use

	input        ld_image,     // the loader writes the image (not a block after it)
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
wire        xs_on  = (loader_en | snap_en) & (xs_space != 3'd0);
wire        xs_attr = xs_on & (xs_space == 3'd3);
wire        mem_on = (~mreq_n | loader_en | snap_en) & ~(xs_on & (xs_space == 3'd3 || xs_space == 3'd5));

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
wire j2  = (mach != 2'd0);
wire j2x = (mach == 2'd2);

// With the Expansion: 4000-7FFF xram; 8000-FFFF page 0 eram, 1 eram1, 2 eram2,
// 3 xram1 (8000-BFFF) and the Expansion ROM (C000-CFFF; D000-FFFF reads FF).
// Otherwise the RAM pack: xram, eram, and the 96K pack's second page xram1, eram1.
wire [1:0] mpage;
wire xram_enable  = j2x ? (mem_on && addr[15:14] == 2'b01)
                        : (mem_on && pack_on && (addr[15:14] == 'b01) && !phys);  // 4000 - 7FFF 16KB
wire eram_enable  = j2x ? (mem_on && addr[15] && mpage == 2'd0)
                        : (mem_on && pack_on && (addr[15])            && !phys);  // 8000 - FFFF 32KB
wire xram1_enable = j2x ? (mem_on && addr[15:14] == 2'b10 && mpage == 2'd3)
                        : (mem_on && pack_on && (addr[15:14] == 'b01) &&  phys);
wire eram1_enable = j2x ? (mem_on && addr[15] && mpage == 2'd1)
                        : (mem_on && pack_on && (addr[15])            &&  phys);
wire eram2_enable = j2x && mem_on && addr[15] && mpage == 2'd2;
wire xrom_enable  = j2x && mem_on && addr[15:12] == 4'hC && mpage == 2'd3;

wire wait_n = no_wait | ~(sram_enable | cram_enable) | hblank | vblank | ~addr[10]; // 2400 - 27FF, 2C00 - 2FFF

always @(posedge clk) begin
	if (~iorq_n & ~cpu_addr[0]) begin
		if (~rd_n) spk <= 0;
		if (~wr_n) {spk,mic} <= {1'b1,cpu_dout[3]};
	end
end

/////////////////  the Expansion's sound chip: registers and I/O ports  /////////////////

reg  [7:0] ay_addr;
reg  [7:0] ay_reg[16];
wire       psg_port = (cpu_addr[7:0] & 8'hF1) == 8'hF1;      // 1111xxx1b
wire [7:0] port_a   = ay_reg[7][6] ? ay_reg[14] : 8'hFF;      // PAPER, INK
wire [7:0] port_b   = ay_reg[7][7] ? ay_reg[15] : 8'hFF;      // BORDER, pages
assign     mpage    = (xs_on && xs_space == 3'd4) ? xs_pg : port_b[1:0];
wire       spage    = j2x ? port_b[2] : j2;                   // screen page
wire       cpage    = j2x ? port_b[3] : j2;                   // character set page
assign     port_b_out = port_b;

// which RAM holds each page: a snapshot's image goes into page 1, and its state
// then says that this is the page shown, whichever that is
reg        sswap = 0, cswap = 0;
always @(posedge clk) begin
	if(mem_cold) begin sswap <= 0; cswap <= 0; end
	else if(xs_swap_set) begin sswap <= xs_sswap; cswap <= xs_cswap; end
end
wire       sp_a = ((xs_on && (xs_space == 3'd1 || xs_space == 3'd3)) ? xs_pg[0] : spage) ^ sswap;
wire       sp_v = spage ^ sswap;
wire       cp_a = ((xs_on && xs_space == 3'd2) ? xs_pg[0] : cpage) ^ cswap;
wire       cp_v = cpage ^ cswap;
genvar gi;
generate for(gi = 0; gi < 16; gi = gi + 1) begin : ayo
	assign ay_regs[gi] = ay_reg[gi];
end endgenerate
assign ay_regs[16] = ay_addr;

always @(posedge clk) begin
	integer i;
	if(reset) begin
		ay_addr <= 0;
		for(i = 0; i < 16; i = i + 1) ay_reg[i] <= 0;
	end
	else if(ay_ld) begin
		if(ay_ld_idx[4]) ay_addr <= loader_data;
		else ay_reg[ay_ld_idx[3:0]] <= loader_data;
	end
	else if(ay_mpage0) begin
		// as Jupiter-IIb's MachineSelectMemoryPage(0): port B made an output, page 0
		ay_reg[15] <= port_b & 8'hFC;
		ay_reg[7]  <= ay_reg[7] | 8'h80;
	end
	else if(j2x && ~iorq_n && m1_n && ~wr_n && cpu_addr[0] && psg_port) begin
		if(~cpu_addr[1]) ay_addr <= cpu_dout;                 // FDh: select a register
		else if(ay_addr < 16) ay_reg[ay_addr[3:0]] <= cpu_dout;
	end
end

// the sound: ay.sv, at 3.25 MHz whatever the CPU speed; writing R13 restarts the envelope
reg  [3:0] ay_div;
reg        ay_wr13;
always @(posedge clk) ay_div <= ay_div + 1'd1;
wire       wr13 = j2x && ~iorq_n && m1_n && ~wr_n && cpu_addr[0] && psg_port && cpu_addr[1] && ay_addr == 8'd13;
always @(posedge clk) ay_wr13 <= wr13;

wire [13:0] ch_a, ch_b, ch_c;
ay ay
(
	.clk(clk),
	.ce_ay(ay_div == 4'd0),
	.reset(reset | ~j2x),
	.r0(ay_reg[0]), .r1(ay_reg[1]), .r2(ay_reg[2]), .r3(ay_reg[3]),
	.r4(ay_reg[4]), .r5(ay_reg[5]), .r6(ay_reg[6]), .r7(ay_reg[7]),
	.r8(ay_reg[8]), .r9(ay_reg[9]), .r10(ay_reg[10]), .r11(ay_reg[11]),
	.r12(ay_reg[12]), .r13(ay_reg[13]),
	.env_restart(ay_wr13 & ~wr13),             // after the write
	.ch_a(ch_a), .ch_b(ch_b), .ch_c(ch_c)
);
assign ay_a = j2x ? ch_a : 14'd0;
assign ay_b = j2x ? ch_b : 14'd0;
assign ay_c = j2x ? ch_c : 14'd0;

// a register as read: unused bits 0, the ports their pins
reg [7:0] ay_read;
always @(*) begin
	case(ay_addr[3:0])
		1, 3, 5, 13: ay_read = ay_reg[ay_addr[3:0]] & 8'h0F;
		6, 8, 9, 10: ay_read = ay_reg[ay_addr[3:0]] & 8'h1F;
		14:          ay_read = port_a;
		15:          ay_read = port_b;
		default:     ay_read = ay_reg[ay_addr[3:0]];
	endcase
end

// odd ports: the Ace's bus shows the video data; the Jupiter II reads FF; with
// the Expansion the sound chip answers at FFh
// the Expansion's 16C450 UART at odd ports 1110rrr1b (E1h - EFh), register in A3 - A1
wire       uart_port = (cpu_addr[7:0] & 8'hF1) == 8'hE1;
wire       uart_sel  = j2x && ~iorq_n && m1_n && uart_port;
wire [7:0] uart_dout;
uart16450 uart
(
	.clk(clk),
	.reset(reset | ~j2x),
	.addr(cpu_addr[3:1]),
	.din(cpu_dout),
	.dout(uart_dout),
	.rd(uart_sel & ~rd_n),
	.wr(uart_sel & ~wr_n),
	.rxd(uart_rxd),
	.txd(uart_txd)
);

wire [7:0] odd_dout = (j2x && uart_port) ? uart_dout :
                      j2x ? ((psg_port && cpu_addr[1] && ay_addr < 16) ? ay_read : 8'hFF) :
                      j2  ? 8'hFF : (sram_data | cram_data);

wire [7:0] io_dout = {8{iorq_n|rd_n}} | (~cpu_addr[0] ? {2'b11, tape_in, kbd_col} : odd_dout);

// Instruction fetch inside the ROM tape loader (0x18A7-0x192C), used for tape autoplay
assign tape_load = ~m1_n & ~mreq_n & (cpu_addr >= 16'h18A7) & (cpu_addr <= 16'h192C);

// The ROM parses the tape name into 2702 (the same RAM as 2302, where the tape
// header is built): remember its first character, 00 or space when blank
always @(posedge clk) if(~mreq_n & ~wr_n & ((cpu_addr & 16'hFBFF) == 16'h2302)) name0 <= cpu_dout;

// Instruction fetch inside the ROM tape saver (0x1820-0x18A6), used by the recorder
assign tape_save = ~m1_n & ~mreq_n & (cpu_addr >= 16'h1820) & (cpu_addr <= 16'h18A6);

// screen and character set RAM: two 1K pages each (the Jupiter Ace uses page 0)
wire [9:0] sram_addr;
wire [7:0] sram_data;
wire [7:0] sram_dout;
dpram #(11) sram
(
	.clock(clk),
	.address_a({sp_a, addr[9:0]}),
	.data_a(data),
	.wren_a(ram_we & sram_enable),
	.oe_a_n(~sram_enable),
	.q_a(sram_dout),
	.address_b({sp_v, sram_addr}),
	.q_b(sram_data)
);

// the Expansion's attribute RAM: written with port A when the CPU writes the screen
wire [7:0] attr_data;
wire [7:0] attr_q;      // the snapshot reads it, the loader writes it (space 3)
dpram #(11) aram
(
	.clock(clk),
	.address_a({sp_a, addr[9:0]}),
	.data_a(xs_attr ? loader_data : port_a),
	.wren_a(xs_attr ? (loader_en & loader_wr) : (j2x & ram_we & sram_enable & ~loader_en & ~snap_en)),
	.oe_a_n(1'b0),
	.q_a(attr_q),
	.address_b({sp_v, sram_addr}),
	.q_b(attr_data)
);

wire [9:0] cram_addr;
wire [7:0] cram_data;
wire [7:0] cram_q;      // the CPU cannot read the character RAM; the snapshot can
dpram #(11) cram
(
	.clock(clk),
	.address_a({cp_a, addr[9:0]}),
	.data_a(data),
	.wren_a(ram_we & cram_enable),
	.oe_a_n(1'b0),
	.q_a(cram_q),
	.address_b({cp_v, cram_addr}),
	.q_b(cram_data)
);

// program RAM: the Ace's 1K seen four times, the Jupiter II's 2K seen twice
wire [7:0] uram_dout;
dpram #(11) uram
(
	.clock(clk),
	.address_a({j2 & addr[10], addr[9:0]}),
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

wire [7:0] eram2_dout;
dpram #(15) eram2
(
	.clock(clk),
	.address_a(addr[14:0]),
	.data_a(data),
	.wren_a(ram_we & eram2_enable),
	.oe_a_n(~eram2_enable),
	.q_a(eram2_dout)
);

wire [7:0] xrom_dout;
dpram #(.ADDRWIDTH(12), .MEM_INIT_FILE("rtl/xrom.mif")) xrom
(
	.clock(clk),
	.address_a(addr[11:0]),
	.oe_a_n(~xrom_enable),
	.q_a(xrom_dout)
);

wire [7:0] pack_dout = xram_dout & eram_dout & xram1_dout & eram1_dout & eram2_dout & xrom_dout;

wire [7:0] rom_q;
wire [12:0] rom_addr = snap_en ? snap_addr[12:0] : cpu_addr[12:0];
dpram #(.ADDRWIDTH(13), .MEM_INIT_FILE("rtl/ace.mif")) rom
(
	.clock(clk),
	.address_a(rom_addr),
	.oe_a_n(~rom_enable),
	.q_a(rom_q)
);

// with the Expansion the boot ROM's patched copy: 008E IM 1 / JR 009Bh -> JP C000h / NOP
reg [12:0] rom_addr_r;
always @(posedge clk) rom_addr_r <= rom_addr;
wire       patched  = j2x && rom_enable && rom_addr_r >= 13'h008E && rom_addr_r <= 13'h0091;
wire [7:0] rom_dout = !patched                ? rom_q :
                      rom_addr_r == 13'h008E  ? 8'hC3 :     // JP C000h
                      rom_addr_r == 13'h0090  ? 8'hC0 : 8'h00;

// snapshot reads: the character RAM, or the other RAMs and the ROM
reg snap_cram, snap_attr;
always @(posedge clk) begin
	snap_cram <= (snap_addr[15:11] == 'b00101) && !(xs_on && xs_space == 3'd3);
	snap_attr <= xs_attr;
end
assign snap_data = snap_attr ? attr_q : snap_cram ? cram_q : (rom_dout & sram_dout & uram_dout & pack_dout);

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
		// the registers are in the image's 2100-217F (not in a block after it, whose
		// bytes may be written through the same addresses)
		if(loader_wr && ld_image && (loader_addr[15:8] == 8'h21) && !loader_addr[7]) begin
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

video video
(
	.clk(clk),
	.ce_pix(ce_pix),
	.j2(j2),
	.colour(j2x),
	.inverse(inverse),
	.sram_addr(sram_addr),
	.sram_data(sram_data),
	.cram_addr(cram_addr),
	.cram_data(cram_data),
	.attr_data(attr_data),
	.border(port_b[7:4]),
	.r(vid_r),
	.g(vid_g),
	.b(vid_b),
	.hsync(hsync),
	.vsync(vsync),
	.hblank(hblank),
	.vblank(vblank)
);

endmodule
