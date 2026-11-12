//============================================================================
//  16C450 UART (the Jupiter II Expansion's serial port)
//
//  Registers 0 - 7 (the Expansion decodes them at odd ports 1110rrr1b, E1h - EFh):
//    0  RBR (read) / THR (write); DLL while LCR bit 7 (DLAB) is set
//    1  IER; DLM while DLAB is set
//    2  IIR (read only)
//    3  LCR: bits 1-0 word length 5-8, bit 2 two stop bits, bit 3 parity on,
//       bit 4 even parity, bit 5 stick parity, bit 6 break, bit 7 DLAB
//    4  MCR: bit 0 DTR, 1 RTS, 2 OUT1, 3 OUT2, 4 loopback
//    5  LSR: bit 0 data ready, 1 overrun, 2 parity error, 3 framing error,
//       4 break, 5 THR empty, 6 transmitter empty
//    6  MSR: CTS and DSR read as set (pulled up on the board), as in Jupiter-IIb;
//       in loopback the MCR outputs
//    7  SCR
//
//  Clocked at 3.6864 MHz (made from clk, CLK_HZ): baud = 230400 / divisor.
//  The interrupt line is not connected on the Expansion, but IIR still says
//  which interrupt would be pending. Side effects of a read (clearing DR, the
//  error bits, a THR empty interrupt) happen at the end of the read cycle.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module uart16450 #(parameter CLK_HZ = 52000000)
(
	input            clk,
	input            reset,

	input      [2:0] addr,     // register
	input      [7:0] din,
	output reg [7:0] dout,
	input            rd,       // a read cycle (level, for the whole cycle)
	input            wr,       // a write cycle (level)

	input            rxd,      // serial line in (idle high)
	output           txd       // serial line out (idle high)
);

/////////////////  registers  /////////////////

reg  [7:0] ier, lcr, mcr, scr, dll, dlm;
reg  [7:0] rbr;
reg        dr, oe, pe, fe, bi;      // line status
reg  [7:0] thr;
reg        thr_full;
reg        tx_busy;
reg        thre_pend;               // the THR empty interrupt (until IIR is read or THR written)

wire       dlab = lcr[7];
wire       loop = mcr[4];
wire       thre = ~thr_full;
wire       temt = ~thr_full & ~tx_busy;
wire [7:0] lsr  = {1'b0, temt, thre, bi, fe, pe, oe, dr};
wire [7:0] msr  = loop ? {mcr[3], mcr[2], mcr[0], mcr[1], 4'd0} : 8'h30;

// interrupt identification, highest priority first
wire [7:0] iir  = (ier[2] & (oe | pe | fe | bi)) ? 8'h06 :
                  (ier[0] & dr)                   ? 8'h04 :
                  (ier[1] & thre & thre_pend)     ? 8'h02 : 8'h01;

always @(*) begin
	case(addr)
		0: dout = dlab ? dll : rbr;
		1: dout = dlab ? dlm : {4'd0, ier[3:0]};
		2: dout = iir;
		3: dout = lcr;
		4: dout = {3'd0, mcr[4:0]};
		5: dout = lsr;
		6: dout = msr;
		default: dout = scr;
	endcase
end

/////////////////  clocks: 3.6864 MHz, then 16 x the baud rate  /////////////////

localparam ACC_STEP = 36864;            // 3686400 / 100
localparam ACC_MOD  = CLK_HZ / 100;
reg [23:0] acc;
reg        tick_uart;
always @(posedge clk) begin
	tick_uart <= 0;
	if(acc + ACC_STEP >= ACC_MOD) begin acc <= acc + ACC_STEP - ACC_MOD; tick_uart <= 1; end
	else acc <= acc + ACC_STEP;
end

wire [15:0] divisor = {dlm, dll};       // 0 counts as 65536
reg  [15:0] div_cnt;
reg         tick16;                      // 16 x baud
always @(posedge clk) begin
	tick16 <= 0;
	if(tick_uart) begin
		if((divisor != 0 && div_cnt + 1'd1 >= divisor) || div_cnt == 16'hFFFF) begin
			div_cnt <= 0;
			tick16  <= 1;
		end
		else div_cnt <= div_cnt + 1'd1;
	end
end

/////////////////  the frame  /////////////////

wire [3:0] nbits_data = 4'd5 + lcr[1:0];
// parity of the data bits in use
function par(input [7:0] d, input [1:0] wl);
	case(wl)
		0: par = ^d[4:0];
		1: par = ^d[5:0];
		2: par = ^d[6:0];
		default: par = ^d;
	endcase
endfunction
// the parity bit to send / expect: odd, even, or stick (mark when EPS = 0)
function pbit(input [7:0] d, input [7:0] l);
	pbit = l[5] ? ~l[4] : (l[4] ? par(d, l[1:0]) : ~par(d, l[1:0]));
endfunction

/////////////////  transmitter  /////////////////

reg [11:0] tsr;         // bits still to send, LSB first
reg  [3:0] tx_left;     // bits left in the frame
reg  [3:0] tx_c16;
reg        tx_line = 1;

always @(posedge clk) begin
	if(reset) begin
		tx_busy <= 0;
		tx_line <= 1;
	end
	else if(!tx_busy) begin
		tx_line <= 1;
		if(thr_full && tick16) begin
			// start bit, data, parity, stop bit(s)
			tx_busy <= 1;
			tx_c16  <= 0;
			tx_line <= 0;                               // the start bit
			tx_left <= nbits_data + lcr[3] + (lcr[2] ? 4'd2 : 4'd1);
			case(lcr[1:0])
				0: tsr <= {6'h3F, lcr[3] ? pbit(thr, lcr) : 1'b1, thr[4:0]};
				1: tsr <= {5'h1F, lcr[3] ? pbit(thr, lcr) : 1'b1, thr[5:0]};
				2: tsr <= {4'hF,  lcr[3] ? pbit(thr, lcr) : 1'b1, thr[6:0]};
				3: tsr <= {3'h7,  lcr[3] ? pbit(thr, lcr) : 1'b1, thr[7:0]};
			endcase
		end
	end
	else if(tick16) begin
		tx_c16 <= tx_c16 + 1'd1;
		if(tx_c16 == 4'd15) begin
			if(tx_left == 0) begin
				tx_busy <= 0;                           // the last stop bit is out
				tx_line <= 1;
			end
			else begin
				tx_line <= tsr[0];
				tsr     <= {1'b1, tsr[11:1]};
				tx_left <= tx_left - 1'd1;
			end
		end
	end
end

// the line: held high in loopback, low while sending a break
assign txd = loop ? 1'b1 : (lcr[6] ? 1'b0 : tx_line);
wire   tx_int = lcr[6] ? 1'b0 : tx_line;            // what the receiver sees in loopback

/////////////////  receiver  /////////////////

reg  [2:0] rx_s = 3'b111;
always @(posedge clk) rx_s <= {rx_s[1:0], loop ? tx_int : rxd};
wire       rx_in = rx_s[2];

reg        rx_busy, rx_wait_high;
reg  [3:0] rx_c16;
reg  [3:0] rx_n;        // bits sampled so far (after the start bit)
reg  [9:0] rx_sh;       // data and parity, LSB first
wire [3:0] rx_total = nbits_data + lcr[3];          // data + parity

// side effects of CPU accesses
reg        old_rd, old_wr;
reg  [2:0] rd_addr;
always @(posedge clk) begin
	old_rd <= rd;
	old_wr <= wr;
	if(rd) rd_addr <= addr;
end
wire rd_end   = old_rd & ~rd;
wire wr_start = ~old_wr & wr;

always @(posedge clk) begin
	if(reset) begin
		ier <= 0; lcr <= 0; mcr <= 0; scr <= 0; dll <= 0; dlm <= 0;
		rbr <= 0; dr <= 0; oe <= 0; pe <= 0; fe <= 0; bi <= 0;
		thr_full <= 0; thre_pend <= 0;
		rx_busy <= 0; rx_wait_high <= 0;
	end
	else begin
		// the transmitter takes the byte in THR
		if(thr_full && !tx_busy && tick16) begin
			thr_full  <= 0;
			thre_pend <= 1;
		end

		// receive: start bit, its middle checked, then a sample in the middle of each bit
		if(tick16) begin
			if(!rx_busy) begin
				if(rx_wait_high) begin
					if(rx_in) rx_wait_high <= 0;
				end
				else if(!rx_in) begin
					rx_busy <= 1;
					rx_c16  <= 0;
					rx_n    <= 0;
				end
			end
			else begin
				rx_c16 <= rx_c16 + 1'd1;
				if(rx_n == 0 && rx_c16 == 4'd7) begin
					if(rx_in) rx_busy <= 0;            // a glitch, not a start bit
					else begin rx_n <= 1; rx_c16 <= 0; end
				end
				else if(rx_n != 0 && rx_c16 == 4'd15) begin
					if(rx_n <= rx_total) begin
						rx_sh <= {rx_in, rx_sh[9:1]};
						rx_n  <= rx_n + 1'd1;
					end
					else begin
						// the stop bit: the character is in
						rx_busy <= 0;
						case(lcr[1:0])
							0: rbr <= {3'd0, rx_sh[9:5]};
							1: rbr <= {2'd0, rx_sh[9:4]};
							2: rbr <= {1'b0, rx_sh[9:3]};
							3: rbr <= rx_sh[9:2];
						endcase
						if(lcr[3]) begin
							case(lcr[1:0])
								0: rbr <= {3'd0, rx_sh[8:4]};
								1: rbr <= {2'd0, rx_sh[8:3]};
								2: rbr <= {1'b0, rx_sh[8:2]};
								3: rbr <= rx_sh[8:1];
							endcase
							pe <= (rx_sh[9] != pbit(rx_sh[8:1] >> (2'd3 - lcr[1:0]), lcr));
						end
						if(dr) oe <= 1;
						dr <= 1;
						if(!rx_in) begin
							fe <= 1;
							if((rx_sh >> (4'd10 - rx_total)) == 0) bi <= 1;
							rx_wait_high <= 1;              // a break: wait for the line to go high
						end
					end
				end
			end
		end

		// CPU writes
		if(wr_start) begin
			case(addr)
				0: if(dlab) dll <= din;
				   else begin thr <= din; thr_full <= 1; thre_pend <= 0; end
				1: if(dlab) dlm <= din;
				   else begin
						ier <= {4'd0, din[3:0]};
						if(din[1] & ~ier[1]) thre_pend <= 1;   // enabled while THR is empty
					end
				3: lcr <= din;
				4: mcr <= {3'd0, din[4:0]};
				7: scr <= din;
				default: ;
			endcase
		end

		// CPU reads, once the read is over
		if(rd_end) begin
			case(rd_addr)
				0: if(!dlab) dr <= 0;
				2: if(iir == 8'h02) thre_pend <= 0;
				5: begin oe <= 0; pe <= 0; fe <= 0; bi <= 0; end
				default: ;
			endcase
		end
	end
end

endmodule
