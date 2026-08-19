// sdram_model.v - behavioral SDRAM model with protocol checking
//
// Same world as the web playground: 4 banks x 8 rows x 8 cols, one byte
// per cell. Command encoding is the real thing: {cs_n, ras_n, cas_n, we_n}
// sampled on posedge clk. Address bus is row/col multiplexed (3 bits).
//
// What it checks (and yells about):
//   - READ/WRITE with no open row
//   - tRCD not satisfied (ACT too recently)
//   - ACT on a bank whose row is still open
//   - ACT before tRP satisfied after PRECHARGE
//   - PRECHARGE before tRAS satisfied (punishes: row data corrupted to x)
//   - AUTO REFRESH while any bank has an open row
//   - capacitor leakage: a row not refreshed within T_LEAK cycles decays
//     to x (reads return x, with a warning) - refresh is not optional
//
// Verilog-2001. Simulate with:  iverilog + vvp  (see Makefile)

`timescale 1ns/1ps

module sdram_model #(
    parameter tRCD   = 2,   // ACT -> READ/WRITE, cycles
    parameter tRP    = 2,   // PRE -> ACT, cycles
    parameter tRAS   = 4,   // ACT -> PRE minimum, cycles
    parameter CL     = 2,   // READ -> data on dq, cycles
    parameter T_LEAK = 200  // cycles until an unrefreshed row decays
)(
    input  wire       clk,
    input  wire       cs_n,
    input  wire       ras_n,
    input  wire       cas_n,
    input  wire       we_n,
    input  wire [1:0] ba,
    input  wire [2:0] addr,   // row or col, multiplexed
    inout  wire [7:0] dq
);

    // ---- storage ------------------------------------------------------
    reg [7:0] mem [0:3][0:7][0:7];        // [bank][row][col]
    integer   last_ref [0:3][0:7];        // cycle of last refresh per row

    // ---- per-bank state ----------------------------------------------
    localparam ST_IDLE = 0, ST_ROWOPEN = 1;
    reg [1:0]  bstate   [0:3];
    reg [2:0]  open_row [0:3];
    integer    t_act    [0:3];            // cycle of last ACT
    integer    t_pre    [0:3];            // cycle of last PRE

    integer cycle;
    integer ref_row;                      // auto refresh internal counter
    integer errors;
    integer warnings;

    // ---- read pipeline (CL delay) ------------------------------------
    reg [7:0] rd_pipe_data  [0:7];
    reg       rd_pipe_valid [0:7];
    reg [7:0] dq_out;
    reg       dq_drive;
    assign dq = dq_drive ? dq_out : 8'hzz;

    // ---- decode -------------------------------------------------------
    wire [2:0] cmd = {ras_n, cas_n, we_n};
    localparam CMD_LMR  = 3'b000;
    localparam CMD_REF  = 3'b001;
    localparam CMD_PRE  = 3'b010;
    localparam CMD_ACT  = 3'b011;
    localparam CMD_WR   = 3'b100;
    localparam CMD_RD   = 3'b101;
    localparam CMD_BST  = 3'b110;
    localparam CMD_NOP  = 3'b111;

    integer b, r, c, i;
    initial begin
        cycle   = 0;
        ref_row = 0;
        errors  = 0;
        warnings = 0;
        dq_drive = 0;
        for (b = 0; b < 4; b = b + 1) begin
            bstate[b] = ST_IDLE;
            open_row[b] = 0;
            t_act[b] = -1000;
            t_pre[b] = -1000;
            for (r = 0; r < 8; r = r + 1) begin
                last_ref[b][r] = 0;
                for (c = 0; c < 8; c = c + 1)
                    mem[b][r][c] = 8'h00;
            end
        end
        for (i = 0; i < 8; i = i + 1) begin
            rd_pipe_valid[i] = 0;
            rd_pipe_data[i]  = 8'h00;
        end
    end

    // leak check helper: is this row still holding charge?
    function row_fresh;
        input integer fb;
        input integer fr;
        begin
            row_fresh = (cycle - last_ref[fb][fr]) < T_LEAK;
        end
    endfunction

    task violation;
        input [511:0] msg;
        begin
            errors = errors + 1;
            $display("[%0d] VIOLATION: %0s", cycle, msg);
        end
    endtask

    task warn;
        input [511:0] msg;
        begin
            warnings = warnings + 1;
            $display("[%0d] WARNING:   %0s", cycle, msg);
        end
    endtask

    // ---- main ---------------------------------------------------------
    always @(posedge clk) begin
        cycle = cycle + 1;

        // advance read pipeline
        dq_drive <= rd_pipe_valid[0];
        dq_out   <= rd_pipe_data[0];
        for (i = 0; i < 7; i = i + 1) begin
            rd_pipe_valid[i] <= rd_pipe_valid[i+1];
            rd_pipe_data[i]  <= rd_pipe_data[i+1];
        end
        rd_pipe_valid[7] <= 0;

        if (!cs_n) begin
            case (cmd)

            CMD_ACT: begin
                if (bstate[ba] == ST_ROWOPEN)
                    violation("ACT on bank with row already open (PRECHARGE first)");
                else if ((cycle - t_pre[ba]) < tRP)
                    violation("ACT before tRP satisfied after PRECHARGE");
                else begin
                    if (!row_fresh_was(ba, addr)) begin
                        // sense amps amplify leaked charge: noise in, noise out.
                        // refresh preserves the living, it does not raise the dead.
                        warn("ACT on a decayed row - contents were already lost");
                        for (c = 0; c < 8; c = c + 1)
                            mem[ba][addr][c] = 8'hxx;
                    end
                    bstate[ba]   <= ST_ROWOPEN;
                    open_row[ba] <= addr;
                    t_act[ba]     = cycle;
                    // sense amps read the row: this refreshes it
                    last_ref[ba][addr] = cycle;
                    $display("[%0d] ACT   bank%0d row%0d", cycle, ba, addr);
                end
            end

            CMD_RD: begin
                if (bstate[ba] != ST_ROWOPEN) begin
                    violation("READ with no open row - dq will be x");
                    rd_pipe_valid[CL-1] <= 1;
                    rd_pipe_data[CL-1]  <= 8'hxx;
                end
                else if ((cycle - t_act[ba]) < tRCD) begin
                    violation("READ before tRCD satisfied - sense amps not done, dq will be x");
                    rd_pipe_valid[CL-1] <= 1;
                    rd_pipe_data[CL-1]  <= 8'hxx;
                end
                else begin
                    rd_pipe_valid[CL-1] <= 1;
                    if (row_fresh(ba, open_row[ba]))
                        rd_pipe_data[CL-1] <= mem[ba][open_row[ba]][addr];
                    else begin
                        warn("READ from decayed row - charge leaked away, dq will be x");
                        rd_pipe_data[CL-1] <= 8'hxx;
                    end
                    $display("[%0d] READ  bank%0d col%0d (data in %0d cycles)", cycle, ba, addr, CL);
                end
            end

            CMD_WR: begin
                if (bstate[ba] != ST_ROWOPEN)
                    violation("WRITE with no open row - data lost");
                else if ((cycle - t_act[ba]) < tRCD)
                    violation("WRITE before tRCD satisfied - data lost");
                else begin
                    mem[ba][open_row[ba]][addr] = dq;
                    last_ref[ba][open_row[ba]] = cycle;
                    $display("[%0d] WRITE bank%0d col%0d = %02h", cycle, ba, addr, dq);
                end
            end

            CMD_PRE: begin
                if (bstate[ba] == ST_ROWOPEN) begin
                    if ((cycle - t_act[ba]) < tRAS) begin
                        violation("PRECHARGE before tRAS satisfied - restore incomplete, row corrupted");
                        for (c = 0; c < 8; c = c + 1)
                            mem[ba][open_row[ba]][c] = 8'hxx;
                    end
                    else begin
                        last_ref[ba][open_row[ba]] = cycle;  // restore = refresh
                        $display("[%0d] PRE   bank%0d row%0d closed", cycle, ba, open_row[ba]);
                    end
                    bstate[ba] <= ST_IDLE;
                    t_pre[ba]   = cycle;
                end
                else
                    $display("[%0d] PRE   bank%0d (already idle)", cycle, ba);
            end

            CMD_REF: begin
                b = 0;
                for (i = 0; i < 4; i = i + 1)
                    if (bstate[i] == ST_ROWOPEN) b = 1;
                if (b)
                    violation("AUTO REFRESH with open row(s) - close all banks first");
                else begin
                    for (i = 0; i < 4; i = i + 1)
                        last_ref[i][ref_row] = cycle;
                    $display("[%0d] REF   all banks row%0d, counter -> row%0d",
                             cycle, ref_row, (ref_row + 1) % 8);
                    ref_row = (ref_row + 1) % 8;
                end
            end

            CMD_NOP: ;  // nothing

            CMD_LMR: $display("[%0d] LMR   (mode register write - accepted, not modeled)", cycle);
            CMD_BST: $display("[%0d] BST   (burst stop - no burst modeled)", cycle);

            endcase
        end
    end

    // helper used inside ACT (checks freshness before last_ref is updated)
    function row_fresh_was;
        input integer fb;
        input integer fr;
        begin
            row_fresh_was = (cycle - last_ref[fb][fr]) < T_LEAK;
        end
    endfunction

    // ---- scoreboard ---------------------------------------------------
    task report;
        begin
            $display("---------------------------------------------");
            $display("model: %0d violations, %0d warnings", errors, warnings);
        end
    endtask

endmodule
