// tb_sdram.v - testbench for sdram_model
//
// A command task library (act / rd / wr / pre / refresh / nop) plus four
// demo scenes:
//   1. the polite sequence : ACT, wait tRCD, WRITE, READ, check, PRE
//   2. crime scene         : READ with no open row, READ before tRCD
//   3. tRAS punishment     : PRE too early corrupts the row
//   4. leakage             : write a byte, go away for T_LEAK cycles
//                            without refreshing, come back to find x
//
// Run:  make        (or: iverilog -g2005 -o tb tb_sdram.v sdram_model.v && vvp tb)
// Wave: make wave   (dumps tb.vcd, open with gtkwave)

`timescale 1ns/1ps

module tb_sdram;

    reg        clk = 0;
    reg        cs_n = 1;
    reg        ras_n = 1, cas_n = 1, we_n = 1;
    reg  [1:0] ba = 0;
    reg  [2:0] addr = 0;

    reg  [7:0] dq_drv;      // testbench write data
    reg        dq_oe = 0;   // testbench drives dq during WRITE
    wire [7:0] dq = dq_oe ? dq_drv : 8'hzz;

    integer pass = 0, fail = 0;

    localparam tRCD = 2, tRP = 2, tRAS = 4, CL = 2, T_LEAK = 60;

    sdram_model #(
        .tRCD(tRCD), .tRP(tRP), .tRAS(tRAS), .CL(CL), .T_LEAK(T_LEAK)
    ) u_sdram (
        .clk(clk), .cs_n(cs_n),
        .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n),
        .ba(ba), .addr(addr), .dq(dq)
    );

    always #5 clk = ~clk;   // 100 MHz

    // ---- command tasks: {ras_n, cas_n, we_n} on one rising edge -------
    task cmd;
        input r_n; input c_n; input w_n;
        input [1:0] tba; input [2:0] taddr;
        begin
            @(negedge clk);
            cs_n = 0; ras_n = r_n; cas_n = c_n; we_n = w_n;
            ba = tba; addr = taddr;
            @(posedge clk);
            #1 cs_n = 1; ras_n = 1; cas_n = 1; we_n = 1;
        end
    endtask

    task nop;   input integer n; integer k;
                begin for (k = 0; k < n; k = k + 1) @(posedge clk); end endtask
    task act;   input [1:0] b; input [2:0] r; begin cmd(0,1,1,b,r); end endtask
    task pre;   input [1:0] b;                begin cmd(0,1,0,b,0); end endtask
    task refresh;                             begin cmd(0,0,1,0,0); end endtask

    task wr;
        input [1:0] b; input [2:0] c; input [7:0] data;
        begin
            @(negedge clk);
            cs_n = 0; ras_n = 1; cas_n = 0; we_n = 0;
            ba = b; addr = c;
            dq_drv = data; dq_oe = 1;
            @(posedge clk);
            #1 cs_n = 1; ras_n = 1; cas_n = 1; we_n = 1; dq_oe = 0;
        end
    endtask

    // read: issues READ, waits CL, samples dq
    task rd;
        input [1:0] b; input [2:0] c; output [7:0] data;
        begin
            @(negedge clk);
            cs_n = 0; ras_n = 1; cas_n = 0; we_n = 1;
            ba = b; addr = c;
            @(posedge clk);
            #1 cs_n = 1; ras_n = 1; cas_n = 1; we_n = 1;
            nop(CL);
            #1 data = dq;
        end
    endtask

    task check;
        input [7:0] got; input [7:0] expect;
        input [255:0] name;
        begin
            if (got === expect) begin
                pass = pass + 1;
                $display("        CHECK PASS: %0s = %02h", name, got);
            end else begin
                fail = fail + 1;
                $display("        CHECK FAIL: %0s = %02h, expected %02h", name, got, expect);
            end
        end
    endtask

    task check_x;
        input [7:0] got;
        input [255:0] name;
        begin
            if (got === 8'hxx) begin
                pass = pass + 1;
                $display("        CHECK PASS: %0s is x (as expected)", name);
            end else begin
                fail = fail + 1;
                $display("        CHECK FAIL: %0s = %02h, expected x", name, got);
            end
        end
    endtask

    reg [7:0] d;

    initial begin
        $dumpfile("tb.vcd");
        $dumpvars(0, tb_sdram);

        nop(4);

        // ---- scene 1: the polite sequence -----------------------------
        $display("");
        $display("==== scene 1: polite read/write ====");
        act(0, 3);            // open bank0 row3
        nop(tRCD);            // wait tRCD
        wr(0, 5, 8'hAB);      // write 0xAB at col5
        rd(0, 5, d);          // read it back (CL handled inside)
        check(d, 8'hAB, "bank0 r3 c5");
        nop(tRAS);            // be polite to tRAS (already spent, but harmless)
        pre(0);               // close row
        nop(tRP);

        // ---- scene 2: crime scene -------------------------------------
        $display("");
        $display("==== scene 2: violations (watch the model yell) ====");
        rd(1, 0, d);          // READ with no open row
        check_x(d, "no-open-row read");
        act(1, 2);
        rd(1, 0, d);          // READ immediately: tRCD not satisfied
        check_x(d, "tRCD-violation read");
        nop(tRAS);
        pre(1);
        nop(tRP);

        // ---- scene 3: tRAS punishment ---------------------------------
        $display("");
        $display("==== scene 3: PRE before tRAS corrupts the row ====");
        act(2, 1);
        nop(1);               // wr lands exactly at tRCD - legal
        wr(2, 0, 8'h77);
        pre(2);               // 3 cycles after ACT: tRAS=4 not satisfied
        nop(tRP);
        act(2, 1);            // reopen
        nop(tRCD);
        rd(2, 0, d);
        check_x(d, "tRAS-punished byte");
        nop(tRAS);
        pre(2);
        nop(tRP);

        // ---- scene 4: leakage -----------------------------------------
        $display("");
        $display("==== scene 4: capacitors leak, refresh or lose it ====");
        act(3, 6);
        nop(tRCD);
        wr(3, 4, 8'h5A);
        nop(tRAS);
        pre(3);               // closed properly, restore counts as refresh
        nop(T_LEAK + 5);      // ...go away too long, no refresh
        act(3, 6);            // model warns: decayed row
        nop(tRCD);
        rd(3, 4, d);
        check_x(d, "leaked byte");
        nop(tRAS);
        pre(3);

        // refresh done right, for contrast
        nop(tRP);
        act(3, 6);
        nop(tRCD);
        wr(3, 4, 8'h5A);
        nop(tRAS);
        pre(3);
        nop(tRP);
        begin : ref_loop
            integer k;
            for (k = 0; k < 8; k = k + 1) begin   // one full refresh sweep
                refresh();
                nop(5);
            end
        end
        act(3, 6);
        nop(tRCD);
        rd(3, 4, d);
        check(d, 8'h5A, "refreshed byte survives");
        nop(tRAS);
        pre(3);

        // ---- verdict --------------------------------------------------
        $display("");
        u_sdram.report;
        $display("tb: %0d passed, %0d failed", pass, fail);
        if (fail == 0)
            $display("tb: ALL GREEN - the cat may now write her own controller");
        else
            $display("tb: FIX ME");
        $finish;
    end

endmodule
