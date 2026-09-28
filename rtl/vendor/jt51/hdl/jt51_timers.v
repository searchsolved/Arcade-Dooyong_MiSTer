/*  This file is part of JT51.

    JT51 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT51 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT51.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 27-10-2016
    */

module jt51_timers(
    input         rst,
    input         clk,
    input         cen,
    input         zero,
    input [9:0]   value_A,
    input [7:0]   value_B,
    input         load_A,
    input         load_B,
    input         clr_flag_A,
    input         clr_flag_B,
    input         enable_irq_A,
    input         enable_irq_B,
    output        flag_A,
    output        flag_B,
    output        overflow_A,
    output        irq_n
);

assign irq_n = ~( (flag_A&enable_irq_A) | (flag_B&enable_irq_B) );

jt51_timer #(.CW(10),.MUL(64)) timer_A(
    .rst        ( rst       ),
    .clk        ( clk       ),
    .cen        ( cen       ),
    .zero       ( zero      ),
    .start_value( value_A   ),
    .load       ( load_A    ),
    .clr_flag   ( clr_flag_A),
    .flag       ( flag_A    ),
    .overflow   ( overflow_A)
);

jt51_timer #(.CW(8),.FREE_EN(1),.MUL(1024)) timer_B(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cen        ( cen           ),
    .zero       ( zero          ),
    .start_value( value_B       ),
    .load       ( load_B        ),
    .clr_flag   ( clr_flag_B    ),
    .flag       ( flag_B        ),
    .overflow   (               )
);

endmodule

module jt51_timer #(parameter
    CW      = 8, // counter bit width. This is the counter that can be loaded
    FREE_EN = 0, // enables a 4-bit free enable count
    MUL     = 64 // Dooyong sim only (JT51_TIMER_EXACT): phiM clocks per count
) (
    input   rst,
    input   clk,
    input   cen,
    input   zero,
    input   [CW-1:0] start_value,
    input   load,
    input   clr_flag,
    output reg flag,
    output reg overflow
);

reg          last_load;
reg [CW-1:0] cnt, next;
reg [   3:0] free_cnt, free_next;
reg          free_ov;

`ifdef JT51_TIMER_EXACT
// Dooyong M3 experiment (not for synthesis): MAME/ymfm timer model, the
// period counted from the load write (cen here is cen_p1 = phiM / 2, hence
// MUL / 2 per count), so the first overflow
// comes exactly MUL*(2^CW - value) clocks after it instead of at the next
// internal sample-cycle tick. See docs/m3_findings.md.
reg [18:0] ex_cnt;
reg        ex_last;
always @(posedge clk, posedge rst)
    if( rst ) begin
        flag <= 1'b0; overflow <= 1'b0; ex_last <= 1'b0; ex_cnt <= 19'd0;
    end else begin
        overflow <= 1'b0;
        if( clr_flag ) flag <= 1'b0;
        ex_last <= load;
        if( load && !ex_last )
            ex_cnt <= 19'(MUL/2) * (19'd1 << CW) - 19'(MUL/2) * {9'd0, start_value};
        else if( load && cen ) begin
            if( ex_cnt <= 19'd1 ) begin
                ex_cnt   <= 19'(MUL/2) * (19'd1 << CW) - 19'(MUL/2) * {9'd0, start_value};
                overflow <= 1'b1;
                flag     <= 1'b1;
            end else ex_cnt <= ex_cnt - 19'd1;
        end
    end
`else
always@(posedge clk, posedge rst)
    if( rst )
        flag <= 1'b0;
    else /*if(cen)*/ begin
        if( clr_flag )
            flag <= 1'b0;
        else if( cen && zero && load && overflow ) flag<=1'b1;
    end

always @(*) begin
    {free_ov, free_next} = { 1'b0, free_cnt} + 1'b1;
    /* verilator lint_off WIDTH */
    {overflow, next }    = { 1'b0, cnt }     + (FREE_EN ? free_ov : 1'b1);
    /* verilator lint_on WIDTH */
end

always @(posedge clk) if(cen && zero) begin : counter
    last_load <= load;
    if( (load && !last_load) || overflow ) begin
      cnt  <= start_value;
    end
    else if( last_load ) cnt <= next;
end

// Free running counter
always @(posedge clk) begin
    if( rst ) begin
        free_cnt <= 4'd0;
    end else if( cen&&zero ) begin
        free_cnt <= free_next;
    end
end
`endif

endmodule
