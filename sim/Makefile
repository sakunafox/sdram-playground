SIM = tb
SRCS = tb_sdram.v sdram_model.v

run: $(SIM)
	vvp $(SIM)

$(SIM): $(SRCS)
	iverilog -g2005 -o $(SIM) $(SRCS)

wave: run
	gtkwave tb.vcd &

clean:
	rm -f $(SIM) tb.vcd

.PHONY: run wave clean
