//============================================================================
//  Jupiter Ace: spool a Forth source file
//
//  OSD "Spool Forth File" (SD slot 3) picks a .fth/.fs/.f file; this module
//  types it into the Ace through the keyboard matrix, line by line, like
//  xAce's spooling. The core runs 8x faster while spooling, with the frame
//  interrupt counted in CPU time, so the ROM sees normal key timing.
//
//  It follows the ROM through its system variables (CPU writes are watched):
//    STATIN 3C28  bit 0 = waiting for input, bits 1-3 caps/graphics/inverse
//    FRAMES 3C2B  written by every frame interrupt, just before the key scan
//    ERR_NO 3C3D  written when an error is reported
//    INSCRN 3C1E, ENDBUF 3C22: after Enter, the line was accepted when
//                 ENDBUF = INSCRN + 2 once the ROM waits for input again
//    FLAGS  3C3E  bit 6 = compiling, sampled at the start of each line
//
//  A key is pressed at a frame interrupt, held for three key scans (the ROM
//  accepts a key on its third scan), released for one, then the next key
//  follows. Text handling, as in xAce:
//    - CR, LF and CR LF end a line; tabs become spaces; other control
//      characters and characters the Ace does not have are skipped
//    - UTF-8 or Latin-1 pound and copyright signs become the Ace's own
//    - ( ... ) comments outside definitions are removed (the Ace would
//      answer them with ERROR 4); inside : DEFINER COMPILER ... ; they are
//      kept, and text after ." and the word after ASCII are left alone
//    - empty lines are not typed
//  Spooling stops at the end of the file, at a line the Ace does not accept
//  (it is left in the editor), or on Stop Spool / Esc. Errors (ERROR n) do
//  not stop it.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//============================================================================

module spool
(
	input             clk,
	input             reset,

	input             img_mounted,  // the file picked in the OSD (SD slot 3)
	input      [63:0] img_size,
	input             stop,         // pulse: Stop Spool or Esc

	output reg [31:0] lba,
	output reg        rd,
	input             ack,
	input       [8:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	input             sd_buff_wr,

	// writes to the Ace system variables 3C00-3C3F
	input             sv_we,
	input       [5:0] sv_addr,
	input       [7:0] sv_data,

	// keyboard matrix
	input       [7:0] kbd_row,
	output      [4:0] kbd_col,

	output reg        active = 0,

	// OSD messages, see the "I" line of CONF_STR
	output reg        info_req,
	output reg  [7:0] info
);

localparam INFO_DONE    = 8'd15;
localparam INFO_DONE_ER = 8'd16;
localparam INFO_BADLINE = 8'd17;
localparam INFO_STOPPED = 8'd18;

// Main_MiSTer mounts games/JupiterACE/boot3.vhd on slot 3 when the core
// starts if there is one: ignore mounts in the first seconds
reg [27:0] start_cnt = 0;
wire       started = start_cnt[27];
always @(posedge clk) if(!started) start_cnt <= start_cnt + 1'd1;

/////////////////  system variables  /////////////////

reg  [7:0] statin = 0, flags = 0;
reg [15:0] inscrn = 0, endbuf = 0;
reg        tick, err;   // pulses: frame interrupt, error reported

always @(posedge clk) begin
	reg old_fr, old_er;

	tick <= 0;
	err  <= 0;
	if(sv_we) begin
		case(sv_addr)
			6'h28: statin       <= sv_data;
			6'h3E: flags        <= sv_data;
			6'h1E: inscrn[7:0]  <= sv_data;
			6'h1F: inscrn[15:8] <= sv_data;
			6'h22: endbuf[7:0]  <= sv_data;
			6'h23: endbuf[15:8] <= sv_data;
		endcase
	end
	old_fr <= sv_we && sv_addr == 6'h2B;
	old_er <= sv_we && sv_addr == 6'h3D;
	if(sv_we && sv_addr == 6'h2B && !old_fr) tick <= 1;
	if(sv_we && sv_addr == 6'h3D && !old_er && sv_data != 8'hFF) err <= 1;
end

/////////////////  keyboard matrix  /////////////////

reg  [4:0] pressed[8];      // keys held by the spooler, per row
assign kbd_col = ~(({5{~kbd_row[0]}} & pressed[0]) | ({5{~kbd_row[1]}} & pressed[1]) |
                   ({5{~kbd_row[2]}} & pressed[2]) | ({5{~kbd_row[3]}} & pressed[3]) |
                   ({5{~kbd_row[4]}} & pressed[4]) | ({5{~kbd_row[5]}} & pressed[5]) |
                   ({5{~kbd_row[6]}} & pressed[6]) | ({5{~kbd_row[7]}} & pressed[7]));

// character -> {valid, CAPS SHIFT, SYMBOL SHIFT, row, column}, from the ROM key tables
function [8:0] key(input [7:0] ch);
	begin
		case(ch)
		8'h20: key = {1'b1, 1'b0, 1'b0, 3'd7, 3'd0};  // ' '
		8'h21: key = {1'b1, 1'b0, 1'b1, 3'd3, 3'd0};  // '!'
		8'h22: key = {1'b1, 1'b0, 1'b1, 3'd5, 3'd0};  // '"'
		8'h23: key = {1'b1, 1'b0, 1'b1, 3'd3, 3'd2};  // '#'
		8'h24: key = {1'b1, 1'b0, 1'b1, 3'd3, 3'd3};  // '$'
		8'h25: key = {1'b1, 1'b0, 1'b1, 3'd3, 3'd4};  // '%'
		8'h26: key = {1'b1, 1'b0, 1'b1, 3'd4, 3'd4};  // '&'
		8'h27: key = {1'b1, 1'b0, 1'b1, 3'd4, 3'd3};  // "'"
		8'h28: key = {1'b1, 1'b0, 1'b1, 3'd4, 3'd2};  // '('
		8'h29: key = {1'b1, 1'b0, 1'b1, 3'd4, 3'd1};  // ')'
		8'h2A: key = {1'b1, 1'b0, 1'b1, 3'd7, 3'd3};  // '*'
		8'h2B: key = {1'b1, 1'b0, 1'b1, 3'd6, 3'd2};  // '+'
		8'h2C: key = {1'b1, 1'b0, 1'b1, 3'd7, 3'd2};  // ','
		8'h2D: key = {1'b1, 1'b0, 1'b1, 3'd6, 3'd3};  // '-'
		8'h2E: key = {1'b1, 1'b0, 1'b1, 3'd7, 3'd1};  // '.'
		8'h2F: key = {1'b1, 1'b0, 1'b1, 3'd7, 3'd4};  // '/'
		8'h30: key = {1'b1, 1'b0, 1'b0, 3'd4, 3'd0};  // '0'
		8'h31: key = {1'b1, 1'b0, 1'b0, 3'd3, 3'd0};  // '1'
		8'h32: key = {1'b1, 1'b0, 1'b0, 3'd3, 3'd1};  // '2'
		8'h33: key = {1'b1, 1'b0, 1'b0, 3'd3, 3'd2};  // '3'
		8'h34: key = {1'b1, 1'b0, 1'b0, 3'd3, 3'd3};  // '4'
		8'h35: key = {1'b1, 1'b0, 1'b0, 3'd3, 3'd4};  // '5'
		8'h36: key = {1'b1, 1'b0, 1'b0, 3'd4, 3'd4};  // '6'
		8'h37: key = {1'b1, 1'b0, 1'b0, 3'd4, 3'd3};  // '7'
		8'h38: key = {1'b1, 1'b0, 1'b0, 3'd4, 3'd2};  // '8'
		8'h39: key = {1'b1, 1'b0, 1'b0, 3'd4, 3'd1};  // '9'
		8'h3A: key = {1'b1, 1'b0, 1'b1, 3'd0, 3'd2};  // ':'
		8'h3B: key = {1'b1, 1'b0, 1'b1, 3'd5, 3'd1};  // ';'
		8'h3C: key = {1'b1, 1'b0, 1'b1, 3'd2, 3'd3};  // '<'
		8'h3D: key = {1'b1, 1'b0, 1'b1, 3'd6, 3'd1};  // '='
		8'h3E: key = {1'b1, 1'b0, 1'b1, 3'd2, 3'd4};  // '>'
		8'h3F: key = {1'b1, 1'b0, 1'b1, 3'd0, 3'd4};  // '?'
		8'h40: key = {1'b1, 1'b0, 1'b1, 3'd3, 3'd1};  // '@'
		8'h41: key = {1'b1, 1'b1, 1'b0, 3'd1, 3'd0};  // 'A'
		8'h42: key = {1'b1, 1'b1, 1'b0, 3'd7, 3'd3};  // 'B'
		8'h43: key = {1'b1, 1'b1, 1'b0, 3'd0, 3'd4};  // 'C'
		8'h44: key = {1'b1, 1'b1, 1'b0, 3'd1, 3'd2};  // 'D'
		8'h45: key = {1'b1, 1'b1, 1'b0, 3'd2, 3'd2};  // 'E'
		8'h46: key = {1'b1, 1'b1, 1'b0, 3'd1, 3'd3};  // 'F'
		8'h47: key = {1'b1, 1'b1, 1'b0, 3'd1, 3'd4};  // 'G'
		8'h48: key = {1'b1, 1'b1, 1'b0, 3'd6, 3'd4};  // 'H'
		8'h49: key = {1'b1, 1'b1, 1'b0, 3'd5, 3'd2};  // 'I'
		8'h4A: key = {1'b1, 1'b1, 1'b0, 3'd6, 3'd3};  // 'J'
		8'h4B: key = {1'b1, 1'b1, 1'b0, 3'd6, 3'd2};  // 'K'
		8'h4C: key = {1'b1, 1'b1, 1'b0, 3'd6, 3'd1};  // 'L'
		8'h4D: key = {1'b1, 1'b1, 1'b0, 3'd7, 3'd1};  // 'M'
		8'h4E: key = {1'b1, 1'b1, 1'b0, 3'd7, 3'd2};  // 'N'
		8'h4F: key = {1'b1, 1'b1, 1'b0, 3'd5, 3'd1};  // 'O'
		8'h50: key = {1'b1, 1'b1, 1'b0, 3'd5, 3'd0};  // 'P'
		8'h51: key = {1'b1, 1'b1, 1'b0, 3'd2, 3'd0};  // 'Q'
		8'h52: key = {1'b1, 1'b1, 1'b0, 3'd2, 3'd3};  // 'R'
		8'h53: key = {1'b1, 1'b1, 1'b0, 3'd1, 3'd1};  // 'S'
		8'h54: key = {1'b1, 1'b1, 1'b0, 3'd2, 3'd4};  // 'T'
		8'h55: key = {1'b1, 1'b1, 1'b0, 3'd5, 3'd3};  // 'U'
		8'h56: key = {1'b1, 1'b1, 1'b0, 3'd7, 3'd4};  // 'V'
		8'h57: key = {1'b1, 1'b1, 1'b0, 3'd2, 3'd1};  // 'W'
		8'h58: key = {1'b1, 1'b1, 1'b0, 3'd0, 3'd3};  // 'X'
		8'h59: key = {1'b1, 1'b1, 1'b0, 3'd5, 3'd4};  // 'Y'
		8'h5A: key = {1'b1, 1'b1, 1'b0, 3'd0, 3'd2};  // 'Z'
		8'h5B: key = {1'b1, 1'b0, 1'b1, 3'd5, 3'd4};  // '['
		8'h5C: key = {1'b1, 1'b0, 1'b1, 3'd1, 3'd2};  // '\\'
		8'h5D: key = {1'b1, 1'b0, 1'b1, 3'd5, 3'd3};  // ']'
		8'h5E: key = {1'b1, 1'b0, 1'b1, 3'd6, 3'd4};  // '^'
		8'h5F: key = {1'b1, 1'b0, 1'b1, 3'd4, 3'd0};  // '_'
		8'h60: key = {1'b1, 1'b0, 1'b1, 3'd0, 3'd3};  // '`'
		8'h61: key = {1'b1, 1'b0, 1'b0, 3'd1, 3'd0};  // 'a'
		8'h62: key = {1'b1, 1'b0, 1'b0, 3'd7, 3'd3};  // 'b'
		8'h63: key = {1'b1, 1'b0, 1'b0, 3'd0, 3'd4};  // 'c'
		8'h64: key = {1'b1, 1'b0, 1'b0, 3'd1, 3'd2};  // 'd'
		8'h65: key = {1'b1, 1'b0, 1'b0, 3'd2, 3'd2};  // 'e'
		8'h66: key = {1'b1, 1'b0, 1'b0, 3'd1, 3'd3};  // 'f'
		8'h67: key = {1'b1, 1'b0, 1'b0, 3'd1, 3'd4};  // 'g'
		8'h68: key = {1'b1, 1'b0, 1'b0, 3'd6, 3'd4};  // 'h'
		8'h69: key = {1'b1, 1'b0, 1'b0, 3'd5, 3'd2};  // 'i'
		8'h6A: key = {1'b1, 1'b0, 1'b0, 3'd6, 3'd3};  // 'j'
		8'h6B: key = {1'b1, 1'b0, 1'b0, 3'd6, 3'd2};  // 'k'
		8'h6C: key = {1'b1, 1'b0, 1'b0, 3'd6, 3'd1};  // 'l'
		8'h6D: key = {1'b1, 1'b0, 1'b0, 3'd7, 3'd1};  // 'm'
		8'h6E: key = {1'b1, 1'b0, 1'b0, 3'd7, 3'd2};  // 'n'
		8'h6F: key = {1'b1, 1'b0, 1'b0, 3'd5, 3'd1};  // 'o'
		8'h70: key = {1'b1, 1'b0, 1'b0, 3'd5, 3'd0};  // 'p'
		8'h71: key = {1'b1, 1'b0, 1'b0, 3'd2, 3'd0};  // 'q'
		8'h72: key = {1'b1, 1'b0, 1'b0, 3'd2, 3'd3};  // 'r'
		8'h73: key = {1'b1, 1'b0, 1'b0, 3'd1, 3'd1};  // 's'
		8'h74: key = {1'b1, 1'b0, 1'b0, 3'd2, 3'd4};  // 't'
		8'h75: key = {1'b1, 1'b0, 1'b0, 3'd5, 3'd3};  // 'u'
		8'h76: key = {1'b1, 1'b0, 1'b0, 3'd7, 3'd4};  // 'v'
		8'h77: key = {1'b1, 1'b0, 1'b0, 3'd2, 3'd1};  // 'w'
		8'h78: key = {1'b1, 1'b0, 1'b0, 3'd0, 3'd3};  // 'x'
		8'h79: key = {1'b1, 1'b0, 1'b0, 3'd5, 3'd4};  // 'y'
		8'h7A: key = {1'b1, 1'b0, 1'b0, 3'd0, 3'd2};  // 'z'
		8'h7B: key = {1'b1, 1'b0, 1'b1, 3'd1, 3'd3};  // '{'
		8'h7C: key = {1'b1, 1'b0, 1'b1, 3'd1, 3'd1};  // '|'
		8'h7D: key = {1'b1, 1'b0, 1'b1, 3'd1, 3'd4};  // '}'
		8'h7E: key = {1'b1, 1'b0, 1'b1, 3'd1, 3'd0};  // '~'
		8'h7F: key = {1'b1, 1'b0, 1'b1, 3'd5, 3'd2};  // ©
		default: key = 9'd0;
		endcase
	end
endfunction

/////////////////  file reader  /////////////////

reg  [7:0] sbuf[512];
reg  [8:0] bi;
reg  [7:0] sbuf_q;
always @(posedge clk) begin
	if(ack & sd_buff_wr) sbuf[sd_buff_addr] <= sd_buff_dout;
	sbuf_q <= sbuf[bi];
end

reg [31:0] size, pos;

// decoded characters, one waiting for the text filter
reg        dq_v, dq_eol;
reg  [7:0] dq_ch;
reg        dec_done;

localparam D_IDLE = 3'd0, D_READ = 3'd1, D_FETCH = 3'd2, D_WAIT = 3'd3, D_BYTE = 3'd4, D_END = 3'd5;
reg  [2:0] dstate = D_IDLE;
reg        ack_seen, prev_cr, prev_c2, last_eol;
reg  [1:0] wt;
reg  [7:0] b;

/////////////////  text filter  /////////////////

reg        cur_v, cur_eol;
reg  [7:0] cur_ch;

reg        tok_v, tok_enter;     // the next thing to type
reg  [7:0] tok_ch;

localparam M_NORMAL = 2'd0, M_COMMENT = 2'd1, M_STRING = 2'd2;
reg  [1:0] mode;
reg        line_start, in_def, ascii_pend, typed_any, ws;
reg  [7:0] wbuf[8];
reg  [3:0] wlen;

/////////////////  typist  /////////////////

localparam T_IDLE = 3'd0, T_MODE = 3'd1, T_NEXT = 3'd2, T_WAITIN = 3'd3, T_HOLD = 3'd4, T_REL = 3'd5, T_ENTER = 3'd6;
reg  [2:0] tstate = T_IDLE;
reg  [1:0] hold;
reg        tok_is_key;   // the key being typed is a token (not a mode switch)
reg        errors;
reg  [8:0] k;

always @(posedge clk) begin
	reg       n_space, def, eow, comment_start, emit;
	reg [8:0] kk;
	reg [7:0] c;
	integer   i;

	info_req <= 0;

	if(reset | (stop & active)) begin
		if(active & ~reset) begin
			info <= INFO_STOPPED; info_req <= 1;
		end
		active <= 0;
		rd     <= 0;
		dstate <= D_IDLE;
		tstate <= T_IDLE;
		for(i = 0; i < 8; i = i + 1) pressed[i] <= 0;
	end
	else if(!active) begin
		if(img_mounted && started && |img_size) begin
			active     <= 1;
			size       <= (|img_size[63:32]) ? 32'hFFFFFFFF : img_size[31:0];
			pos        <= 0;
			lba        <= 0;
			dq_v       <= 0;
			dec_done   <= 0;
			prev_cr    <= 0;
			prev_c2    <= 0;
			last_eol   <= 1;
			cur_v      <= 0;
			tok_v      <= 0;
			mode       <= M_NORMAL;
			line_start <= 1;
			typed_any  <= 0;
			ws         <= 1;
			wlen       <= 0;
			ascii_pend <= 0;
			in_def     <= 0;
			errors     <= 0;
			dstate     <= D_READ;
			rd         <= 1;
			ack_seen   <= 0;
			tstate     <= T_MODE;
		end
	end
	else begin
		if(err) errors <= 1;

		//////// file reader and character decoder ////////
		case(dstate)
			D_READ:
				if(ack) begin
					rd       <= 0;
					ack_seen <= 1;
				end
				else if(ack_seen) begin
					ack_seen <= 0;
					dstate   <= D_FETCH;
				end

			D_FETCH: begin
					bi     <= pos[8:0];
					wt     <= 2;
					dstate <= D_WAIT;
				end

			D_WAIT:
				if(wt) wt <= wt - 1'd1;
				else begin
					b      <= sbuf_q;
					dstate <= D_BYTE;
				end

			D_BYTE:
				if(!dq_v) begin
					// decode one byte; at most one character comes out
					emit = 0; c = 0;
					prev_cr <= (b == 8'h0D);
					prev_c2 <= (b == 8'hC2);
					if(prev_c2 && b[7:6] == 2'b10) begin
						if(b == 8'hA3) begin emit = 1; c = 8'h60; end        // pound
						else if(b == 8'hA9) begin emit = 1; c = 8'h7F; end   // copyright
					end
					else if(prev_cr && b == 8'h0A) ;                          // CR LF
					else if(b == 8'h0D || b == 8'h0A) begin emit = 1; c = 8'h0A; end
					else if(b == 8'h09) begin emit = 1; c = 8'h20; end
					else if(b >= 8'h20 && b < 8'h80) begin emit = 1; c = b; end
					else if(b == 8'hA3) begin emit = 1; c = 8'h60; end        // Latin-1
					else if(b == 8'hA9) begin emit = 1; c = 8'h7F; end
					if(emit) begin
						dq_v     <= 1;
						dq_eol   <= (c == 8'h0A);
						dq_ch    <= c;
						last_eol <= (c == 8'h0A);
					end
					pos <= pos + 1'd1;
					if(pos + 1'd1 >= size) dstate <= D_END;
					else if(pos[8:0] == 9'd511) begin
						lba      <= lba + 1'd1;
						rd       <= 1;
						ack_seen <= 0;
						dstate   <= D_READ;
					end
					else dstate <= D_FETCH;
				end

			D_END:
				if(!dq_v) begin
					// a last line without a line end still gets one
					if(!last_eol) begin
						dq_v     <= 1;
						dq_eol   <= 1;
						dq_ch    <= 8'h0A;
						last_eol <= 1;
					end
					else begin
						dec_done <= 1;
						dstate   <= D_IDLE;
					end
				end
		endcase

		//////// text filter: one character at a time, seeing the next one ////////
		if(!cur_v) begin
			if(dq_v) begin
				cur_v   <= 1;
				cur_eol <= dq_eol;
				cur_ch  <= dq_ch;
				dq_v    <= 0;
			end
		end
		else if(!tok_v && (dq_v || dec_done)) begin
			n_space = !dq_v || dq_eol || dq_ch == 8'h20;
			def = line_start ? flags[6] : in_def;   // compiling state when the line starts
			line_start <= 0;
			in_def     <= def;

			// end of a word: look at it
			eow = (cur_eol || cur_ch == 8'h20) && mode == M_NORMAL && wlen != 0;
			if(eow) begin
				if(wlen == 1 && wbuf[0] == ":") def = 1;
				if(wlen == 1 && wbuf[0] == ";") def = 0;
				if(wlen == 7 && {wbuf[0],wbuf[1],wbuf[2],wbuf[3],wbuf[4],wbuf[5],wbuf[6]} == "DEFINER") def = 1;
				if(wlen == 8 && {wbuf[0],wbuf[1],wbuf[2],wbuf[3],wbuf[4],wbuf[5],wbuf[6],wbuf[7]} == "COMPILER") def = 1;
				in_def <= def;
				if(ascii_pend) ascii_pend <= 0;
				else if(wlen == 5 && {wbuf[0],wbuf[1],wbuf[2],wbuf[3],wbuf[4]} == "ASCII") ascii_pend <= 1;
				if(wlen == 2 && wbuf[0] == "." && wbuf[1] == 8'h22 && !cur_eol) mode <= M_STRING;
				wlen <= 0;
			end

			if(cur_eol) begin
				if(typed_any) begin
					tok_v     <= 1;
					tok_enter <= 1;
				end
				mode       <= M_NORMAL;
				line_start <= 1;
				typed_any  <= 0;
				ws         <= 1;
				wlen       <= 0;
				ascii_pend <= 0;
			end
			else if(mode == M_COMMENT) begin
				if(cur_ch == ")") begin
					mode <= M_NORMAL;
					ws   <= 1;
				end
			end
			else if(mode == M_STRING) begin
				tok_v     <= 1;
				tok_enter <= 0;
				tok_ch    <= cur_ch;
				if(cur_ch == 8'h22) mode <= M_NORMAL;
			end
			else if(cur_ch == 8'h20) begin
				ws <= 1;
				if(typed_any) begin
					tok_v     <= 1;
					tok_enter <= 0;
					tok_ch    <= 8'h20;
				end
			end
			else begin
				comment_start = ws && cur_ch == "(" && n_space && !def && !ascii_pend;
				if(comment_start) mode <= M_COMMENT;
				else begin
					tok_v     <= 1;
					tok_enter <= 0;
					tok_ch    <= cur_ch;
					typed_any <= 1;
					// compared in capitals, as the Ace finds words whatever their case
					if(wlen < 8) wbuf[wlen[2:0]] <= (cur_ch >= "a" && cur_ch <= "z") ? cur_ch - 8'h20 : cur_ch;
					if(wlen != 4'd15) wlen <= wlen + 1'd1;
				end
				ws <= 0;
			end

			// next character
			if(dq_v) begin
				cur_eol <= dq_eol;
				cur_ch  <= dq_ch;
				dq_v    <= 0;
			end
			else cur_v <= 0;
		end

		//////// typist ////////
		case(tstate)
			T_MODE:   // caps lock, graphics and inverse off first, as xAce does
				if(tick && statin[0]) begin
					if(statin[1])      begin k <= 9'b1_10_011_001; tok_is_key <= 0; pressed[0][0] <= 1; pressed[3][1] <= 1; hold <= 0; tstate <= T_HOLD; end
					else if(statin[2]) begin k <= 9'b1_10_100_001; tok_is_key <= 0; pressed[0][0] <= 1; pressed[4][1] <= 1; hold <= 0; tstate <= T_HOLD; end
					else if(statin[3]) begin k <= 9'b1_10_011_011; tok_is_key <= 0; pressed[0][0] <= 1; pressed[3][3] <= 1; hold <= 0; tstate <= T_HOLD; end
					else tstate <= T_NEXT;
				end

			T_NEXT:
				if(tok_v) begin
					if(tok_enter) begin k <= 9'b1_00_110_000; tstate <= T_WAITIN; end
					else begin
						kk = key(tok_ch);
						if(kk[8]) begin k <= kk; tstate <= T_WAITIN; end
						else tok_v <= 0;                 // no such key on the Ace
					end
					tok_is_key <= 1;
				end
				else if(dec_done && !cur_v && !dq_v) begin
					info   <= errors ? INFO_DONE_ER : INFO_DONE; info_req <= 1;
					active <= 0;
					tstate <= T_IDLE;
				end

			T_WAITIN:   // press at a frame interrupt, while the ROM waits for input
				if(tick && statin[0]) begin
					pressed[k[5:3]][k[2:0]] <= 1;
					if(k[7]) pressed[0][0] <= 1;
					if(k[6]) pressed[0][1] <= 1;
					hold   <= 0;
					tstate <= T_HOLD;
				end

			T_HOLD:     // held for three key scans, released at the fourth
				if(tick) begin
					if(hold == 2) begin
						for(i = 0; i < 8; i = i + 1) pressed[i] <= 0;
						tstate <= T_REL;
					end
					else hold <= hold + 1'd1;
				end

			T_REL:      // one scan with no key, so the next one counts as new
				if(tick) begin
					if(!tok_is_key) tstate <= T_MODE;
					else if(tok_enter) tstate <= T_ENTER;
					else begin
						tok_v  <= 0;
						tstate <= T_NEXT;
					end
				end

			T_ENTER:    // the ROM ran the line; accepted when the input line is empty
				if(statin[0]) begin
					if(endbuf == inscrn + 16'd2) begin
						tok_v  <= 0;
						tstate <= T_NEXT;
					end
					else begin
						info   <= INFO_BADLINE; info_req <= 1;
						active <= 0;
						tstate <= T_IDLE;
					end
				end
		endcase
	end
end

endmodule
