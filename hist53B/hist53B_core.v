/**
 * ------------------------------------------------------------
 * Copyright (c) All rights reserved
 * SiLab, Institute of Physics, University of Bonn, by Tobias B.
 * ------------------------------------------------------------
 */ 

`timescale 1ps/1ps

module hist53B_core
#(
    parameter                   ABUSWIDTH = 32
) (
    input wire                  BUS_CLK,
    input wire                  BUS_RST,
    input wire [ABUSWIDTH-1:0]  BUS_ADD,
    input wire [7:0]            BUS_DATA_IN,
    input wire                  BUS_RD,
    input wire                  BUS_WR,
    output reg [7:0]            BUS_DATA_OUT,

    input wire [63:0]           AURORA_RX_TDATA,
    input wire                  AURORA_RX_TVALID,
    input wire                  USER_CLK

);

localparam VERSION = 1;
localparam REGSIZE = 8;


// General parameters
// There are 384 * 400 = 153.6k pixels, thus we use 2**18 = 262.1kbyte 
localparam BRAM_ADD_WIDTH = 14;
localparam BRAM_NUMBER_OF_BLOCKS = 2**BRAM_ADD_WIDTH;

// Each Pixelblock contains 16 pixels (2**4)
localparam BLOCK_ADD_WIDTH = 4;
localparam PIXELS_PER_PIXELBLOCK = 2**BLOCK_ADD_WIDTH;  // 16 Pixels
localparam BITS_PER_PIXEL = 8; // smaller / equal 8
localparam BRAM_DATA_WIDTH = PIXELS_PER_PIXELBLOCK * BITS_PER_PIXEL; // in bits 128


// Set Resets for both clocks
wire RST = BUS_RST || (BUS_ADD==0 && BUS_WR);
wire RST_USER_CLK;
cdc_reset_sync i_cdc_reset_sync (
    .clk_in(BUS_CLK),
    .pulse_in(RST),
    .clk_out(USER_CLK),
    .pulse_out(RST_USER_CLK)
);


// Reorder Aurora data signal
wire [63:0] DATA_IN;
assign DATA_IN = {AURORA_RX_TDATA[7:0], AURORA_RX_TDATA[15:8], AURORA_RX_TDATA[23:16], AURORA_RX_TDATA[31:24], AURORA_RX_TDATA[39:32], AURORA_RX_TDATA[47:40], AURORA_RX_TDATA[55:48], AURORA_RX_TDATA[63:56]};


// Registers mainly used for testing
reg [7:0] inner_regs [REGSIZE-1:0];
always @(posedge BUS_CLK) begin
    if(RST) begin
        inner_regs[0] <= 0;
        inner_regs[1] <= 0; // 
        inner_regs[2] <= 0; // example Qrow
        inner_regs[3] <= 0; // example hitmap[7:0]
        inner_regs[4] <= 0; // example hitmap[15:8]
        inner_regs[5] <= 0; // islast, isneighbor, 6'b0
        inner_regs[6] <= 0; 
        inner_regs[7] <= 0; // recording, 0, example Ccol
    end else if(BUS_WR && BUS_ADD < REGSIZE)
        inner_regs[BUS_ADD[2:0]] <= BUS_DATA_IN;
end

// testing
wire [5:0] CCOL;
assign CCOL = inner_regs[7][5:0];
wire [7:0] QROW;
assign QROW = inner_regs[2];
wire [15:0] HITMAP;
assign HITMAP = {inner_regs[4], inner_regs[3]};
reg [7:0] COUNTER = 8'b0;


// BRAM INIT
wire BUS_MEM_EN;
wire [ABUSWIDTH-1:0] BUS_MEM_ADD;

(* RAM_STYLE = "{BLOCK_POWER2}" *)
reg [BRAM_DATA_WIDTH-1:0] mem [BRAM_NUMBER_OF_BLOCKS-1:0];

integer bram_clear_ind;
initial begin
   for (bram_clear_ind = 0; bram_clear_ind < BRAM_NUMBER_OF_BLOCKS; bram_clear_ind = bram_clear_ind + 1) begin
       mem[bram_clear_ind] = 0;
   end
end


// Recording wire toggles the main Analysis
wire RECORDING;
assign RECORDING = inner_regs[7][7];

// Flag will flip to 1'b1 if FIFO was FULL at any point
reg OVERFLOW_FLAG = 1'b0;

// Map address space
reg [7:0] BUS_DATA_OUT_REG;
always @ (posedge BUS_CLK) begin
    if(BUS_RD) begin
        if(BUS_ADD == 0)
            BUS_DATA_OUT_REG <= VERSION;
        else if (BUS_ADD == 1)
            BUS_DATA_OUT_REG <= COUNTER;
        else if (BUS_ADD == 5)
            BUS_DATA_OUT_REG <= BRAM_ADD_WIDTH;
        else if (BUS_ADD == 6)
            BUS_DATA_OUT_REG <= REGSIZE;
        else if (BUS_ADD == 7)
            BUS_DATA_OUT_REG <= {OVERFLOW_FLAG, 7'b0};
    end
    else
        BUS_DATA_OUT_REG <= 8'h00;
end

// wait cycle for bram (for write / read)
reg [ABUSWIDTH-1:0] PREV_BUS_ADD = 16'h0000;
always @ (posedge BUS_CLK) begin
    if(BUS_RD)
        PREV_BUS_ADD <= BUS_ADD;
    else
        PREV_BUS_ADD <= 16'h0000;
end

reg [BRAM_DATA_WIDTH-1:0] BRAM_READ_VALUE;
// Mux: RAM, registers
always @(*) begin
    if(PREV_BUS_ADD < REGSIZE) begin
        BUS_DATA_OUT = BUS_DATA_OUT_REG;
    end else if(PREV_BUS_ADD < (REGSIZE + (BRAM_NUMBER_OF_BLOCKS * PIXELS_PER_PIXELBLOCK))) begin
        BUS_DATA_OUT = BRAM_READ_VALUE[(BUS_ADD[3:0] * BITS_PER_PIXEL) +: BITS_PER_PIXEL];
    end else begin
        BUS_DATA_OUT = 8'h10;
    end
end

// AURORA Stream into FIFO
wire AURORA_FIFO_WRITE;
wire AURORA_FIFO_READ;
wire AURORA_FIFO_FULL;
wire AURORA_FIFO_EMPTY;
wire [63:0] AURORA_FIFO_DATA;
assign AURORA_FIFO_WRITE = (!AURORA_FIFO_FULL) && AURORA_RX_TVALID && RECORDING;

reg OVERWRITE = 1'b0;
reg FIFO_NEED_READ = 1'b0;
assign AURORA_FIFO_READ = FIFO_NEED_READ && (AURORA_FIFO_EMPTY || OVERWRITE);

// reg [63:0] test_DATA_IN = 1;
// reg [1:0] test_DATA_STATE = 2'b00;

// always @(posedge USER_CLK) begin
//     if (AURORA_FIFO_WRITE) begin
//         case (test_DATA_STATE)
//             2'b00 : test_DATA_IN  <= 64'b1_0001_0000_00_1010_1_0_0000_1010_1111_0100_0010_1111__000_00000_00000_00000_00000;
//             2'b01 : test_DATA_IN  <= 64'b1_0001_0000_00_1011_0_0_0000_1001_1111_0100_0010_1111__00_0000_1000_1111_0100_0010_1;
//             2'b10 : test_DATA_IN  <= 64'b0_111__00_0000_1010_1111_0100_0010_1111__11_0000_1011_1101_0000__000000_0000_00_0000;
//             2'b11 : test_DATA_IN  <= 64'b1_0001_0000_00_1000_1_0_0000_1010_1111_0100_0010_1111__000_00000_00000_00000_00000;
//         endcase
//         test_DATA_STATE = test_DATA_STATE + 1;
//     end
// end


    cdc_syncfifo #(
        .DSIZE(64),
        .ASIZE(5)
    ) cdc_syncfifo_i (
        .rdata(AURORA_FIFO_DATA),
        .wfull(AURORA_FIFO_FULL),
        .rempty(AURORA_FIFO_EMPTY),
        .wdata(DATA_IN), // test_DATA_IN
        .winc(AURORA_FIFO_WRITE), 
        .wclk(USER_CLK), 
        .wrst(RST_USER_CLK),
        .rinc(AURORA_FIFO_READ), 
        .rclk(BUS_CLK), 
        .rrst(BUS_RST)
    );

// set OVERFLOW Flag if FIFO was full
always @(posedge USER_CLK) begin
    if (AURORA_FIFO_FULL) begin
        OVERFLOW_FLAG <= 1'b1;
    end
end

// Stream to Window
reg [63:0] DATA_CURRENT = 64'b0;
reg [63:0] DATA_NEXT = 64'b0;
wire [50:0] ACTIVE_WINDOW;
reg [7:0] OFFSET_r = 8'b0;

generate
   genvar window_slice;
   for (window_slice = 0; window_slice < 51; window_slice = window_slice + 1) begin
       assign ACTIVE_WINDOW[window_slice] = (OFFSET_r + (50-window_slice) < 63) ?  DATA_CURRENT[(62 - OFFSET_r) -  (50 - window_slice)] : DATA_NEXT[(62 - OFFSET_r + 63) - (50 - window_slice)];
   end
endgenerate

// For Testing purpuses
// reg [50:0] ACTIVE_WINDOW_TEST = 51'b00000000__001010__0__0__00001010__11110100_00101111__1__1__11110100_0;
// assign ACTIVE_WINDOW = ACTIVE_WINDOW_TEST;

// Window to Event
// Eventparameter for next event
reg NEW_STREAM_r = 1'b1;
reg ISLAST_r = 1'b1; 
reg [29:0] EVENT_r = 30'b0;
reg EVENT_READY_r;

reg INNER_TAG_w = 1'b0;
reg  ISNEIGHBOR_w = 1'b0;

// Inner Tag
always @(*) begin
    if (ACTIVE_WINDOW[(50 - 8*NEW_STREAM_r) -: 6] > 6'd55) begin
        INNER_TAG_w = 1'b1;
    end else begin
        INNER_TAG_w = 1'b0;
    end
end 

always @(*) begin
    ISNEIGHBOR_w = ACTIVE_WINDOW[(49 - 6*ISLAST_r - 8*NEW_STREAM_r - 11*INNER_TAG_w)];
end


// Last values of Ccol & Qrow
reg [5:0] CCOL_LAST_r = 6'b0;
reg [7:0] QROW_LAST_r [55:1];
integer k;
initial begin
    for (k = 1; k <= 55; k = k+1) begin
        QROW_LAST_r[k] = 8'b0;
    end
end

// Current state: 0 load, 1 event logic
localparam STATE_PROCESSING = 3'b000;
localparam STATE_STAY = 3'b001;
localparam STATE_PUSH_ZERO = 3'b010;
localparam STATE_PUSH_FIFO = 3'b011;
localparam STATE_PUSH_NEW_EVENT = 3'b100;
localparam STATE_TRY_PUSH_FIFO = 3'b101;
reg [2:0] CURRENT_STATE = 3'b000;

integer RST_INT;
always @(posedge BUS_CLK) begin
    // RECORING starts/stops
    if (RST) begin
        CURRENT_STATE <= STATE_PROCESSING;
        EVENT_READY_r <= 0;
        FIFO_NEED_READ <= 0;
        NEW_STREAM_r <= 1'b1;
        OFFSET_r <= 8'b0;
        ISLAST_r <= 1'b1;
        OVERWRITE <= 1'b0;
        CCOL_LAST_r <= 6'b0;
        DATA_CURRENT <= 64'b0;
        DATA_NEXT <= 64'b0;
        for (RST_INT = 1; RST_INT < 56; RST_INT = RST_INT + 1) QROW_LAST_r[RST_INT] <= 8'b0000_0000;

    end else begin
        if (RECORDING) begin
            case (CURRENT_STATE)
            // Event processing
                STATE_PROCESSING : begin
                    // checking for ZERO EVENT: skip and load
                    if(ACTIVE_WINDOW[50 - 8*NEW_STREAM_r - 11*INNER_TAG_w -: 10] == 10'b0000_0000) begin
                        EVENT_READY_r <= 1'b0;

                        // if EMPTY: wait
                        if (AURORA_FIFO_EMPTY) begin
                            CURRENT_STATE <= STATE_PROCESSING;
                            FIFO_NEED_READ <= 0;
                            OVERWRITE <= 1'b0;
                        // else: LOAD events
                        end else begin
                            CURRENT_STATE <= STATE_PUSH_NEW_EVENT;
                            FIFO_NEED_READ <= 1;
                            NEW_STREAM_r <= 1'b1;
                            OFFSET_r <= 8'b0;
                            ISLAST_r <= 1'b1;
                            OVERWRITE <= 1'b1; // TEST!
                        end
                        // Todo remove 0_... as they make no sense

                    // standart event
                    end else begin
                        // CCOL & QROW
                        if (ISLAST_r) begin
                            EVENT_r[29:24] <= ACTIVE_WINDOW[(50 - 8*NEW_STREAM_r - 11*INNER_TAG_w)-: 6];
                            CCOL_LAST_r <= ACTIVE_WINDOW[(50 - 8*NEW_STREAM_r - 11*INNER_TAG_w)-: 6];
                            if(ISNEIGHBOR_w) begin
                                EVENT_r[23:16] <= QROW_LAST_r[ACTIVE_WINDOW[(50 - 8*NEW_STREAM_r - 11*INNER_TAG_w)-: 6]] + 8'b1;
                                QROW_LAST_r[ACTIVE_WINDOW[(50 - 8*NEW_STREAM_r - 11*INNER_TAG_w)-: 6]] <= QROW_LAST_r[ACTIVE_WINDOW[(50 - 8*NEW_STREAM_r - 11*INNER_TAG_w)-: 6]] + 8'b1;
                            end else begin
                                EVENT_r[23:16] <= ACTIVE_WINDOW[(48 - 6*ISLAST_r - 8*NEW_STREAM_r - 11*INNER_TAG_w) -: 8];
                                QROW_LAST_r[ACTIVE_WINDOW[(50 - 8*NEW_STREAM_r - 11*INNER_TAG_w)-: 6]] <= ACTIVE_WINDOW[(48 - 6*ISLAST_r - 8*NEW_STREAM_r - 11*INNER_TAG_w) -: 8];
                            end    
                        end else begin
                            EVENT_r[29:24] <= CCOL_LAST_r;
                            if(ISNEIGHBOR_w) begin
                                EVENT_r[23:16] <= QROW_LAST_r[CCOL_LAST_r] + 8'b1;
                                QROW_LAST_r[CCOL_LAST_r] <= QROW_LAST_r[CCOL_LAST_r] + 8'b1;
                            end else begin
                                EVENT_r[23:16] <= ACTIVE_WINDOW[(48 - 6*ISLAST_r - 8*NEW_STREAM_r - 11*INNER_TAG_w) -: 8];
                                QROW_LAST_r[CCOL_LAST_r] <= ACTIVE_WINDOW[(48 - 6*ISLAST_r - 8*NEW_STREAM_r - 11*INNER_TAG_w) -: 8];
                            end      
                        end 

                        // HITMAP
                        EVENT_r[15:0] <= ACTIVE_WINDOW[(40 + 8*ISNEIGHBOR_w - 6*ISLAST_r - 8*NEW_STREAM_r - 11*INNER_TAG_w) -: 16];

                        // Set new Parameters
                        EVENT_READY_r <= 1'b1;
                        ISLAST_r <= ACTIVE_WINDOW[(50 - 8*NEW_STREAM_r - 11*INNER_TAG_w - 6*ISLAST_r)];
                        NEW_STREAM_r <= 1'b0;

                        // wire [8:0] DEBUG;
                        // assign DEBUG = 6*ISLAST_r + 8*NEW_STREAM_r + 11*INNER_TAG_w;
                        
                        // Check if the Window has moved out of DATA_CURRENT
                        if ((OFFSET_r + 26 - 8*ISNEIGHBOR_w + 6*ISLAST_r + 8*NEW_STREAM_r + 11*INNER_TAG_w) > 62) begin
                            OFFSET_r <= OFFSET_r + (26 - 8*ISNEIGHBOR_w + 6*ISLAST_r + 8*NEW_STREAM_r + 11*INNER_TAG_w) - 63;
                            
                            // If empty wait until you can pull
                            if (AURORA_FIFO_EMPTY) begin
                                CURRENT_STATE <= STATE_TRY_PUSH_FIFO;
                                FIFO_NEED_READ <= 1;
                                OVERWRITE <= 1'b0;
                            // Other wise pull if it's in same stream
                            end else if(!AURORA_FIFO_EMPTY && (AURORA_FIFO_DATA[63] == 0)) begin
                                CURRENT_STATE <= STATE_PUSH_FIFO;
                                FIFO_NEED_READ <= 1;
                                OVERWRITE <= 1'b1;
                            // If not fill up with 0's
                            end else begin
                                CURRENT_STATE <= STATE_PUSH_ZERO;
                                FIFO_NEED_READ <= 0;
                            end

                        // Staying within DATA_CURRENT
                        end else begin
                            CURRENT_STATE <= STATE_PROCESSING;
                            FIFO_NEED_READ <= 0;
                            OFFSET_r <= OFFSET_r + 26 - 8*ISNEIGHBOR_w + 6*ISLAST_r + 8*NEW_STREAM_r + 11*INNER_TAG_w;
                        end 
                    end
                end

            // Pushing Zero in empty FIFO- or new Stream case
                STATE_PUSH_ZERO : begin
                    CURRENT_STATE <= STATE_PROCESSING;
                    DATA_CURRENT <= DATA_NEXT;
                    DATA_NEXT <= 64'b0;
                    EVENT_READY_r <= 1'b0;
                    FIFO_NEED_READ <= 0;
                end
            // Pushing next Fifo data
                STATE_PUSH_FIFO: begin
                    CURRENT_STATE <= STATE_PROCESSING;
                    DATA_CURRENT <= DATA_NEXT;
                    DATA_NEXT <= AURORA_FIFO_DATA;
                    EVENT_READY_r <= 1'b0;
                    FIFO_NEED_READ <= 0;
                end
            // Try Pushing next Fifo data
                STATE_TRY_PUSH_FIFO: begin
                    // stay in mode until we can check next Frame
                    EVENT_READY_r <= 1'b0;
                    if (AURORA_FIFO_EMPTY) begin
                        CURRENT_STATE <= STATE_TRY_PUSH_FIFO;
                        FIFO_NEED_READ <= 1;
                        OVERWRITE <= 1'b0;
                    // if next frame is part of Stream add it 
                    end else if (AURORA_FIFO_DATA[63] == 0) begin
                        CURRENT_STATE <= STATE_PROCESSING;
                        DATA_NEXT <= AURORA_FIFO_DATA;
                        DATA_CURRENT <= DATA_NEXT;
                        FIFO_NEED_READ <= 0;
                    // otherwise fill up with zeros
                    end else begin
                        CURRENT_STATE <= STATE_PROCESSING;
                        DATA_NEXT <= 64'b0;
                        DATA_CURRENT <= DATA_NEXT;
                        FIFO_NEED_READ <= 0;
                    end
                end
            // Pushing new Streamevent from FIFO
                STATE_PUSH_NEW_EVENT: begin
                    CURRENT_STATE <= STATE_TRY_PUSH_FIFO;
                    FIFO_NEED_READ <= 1;
                    OVERWRITE <= 1'b1;
                    DATA_CURRENT <= 64'b0;
                    DATA_NEXT <= AURORA_FIFO_DATA;
                    NEW_STREAM_r <= 1'b1;
                    EVENT_READY_r <= 1'b0;
                end
                default: ; // do nothing;
            endcase  
        end
    end
end 


// Increment corresponding register in BRAM if EVENT_READY_r == 1
wire [5:0] CCOL_w;
assign CCOL_w = EVENT_r[29:24]; //  6'b000000; //
wire [7:0] QROW_w;
assign QROW_w =  EVENT_r[23:16]; // 8'b00000000; //
wire [15:0] HITMAP_w;
assign HITMAP_w = EVENT_r[15:0]; // 16'b1111_0100_0010_1111; 


// Write to BRAM
reg [BRAM_ADD_WIDTH-1:0] WRITE_ADDRESS = 14'b0;
reg [BRAM_DATA_WIDTH-1:0] WRITE_VALUE = 0;
reg WRITE_TOGGLE = 0;
always @(posedge BUS_CLK) begin
    if (WRITE_TOGGLE) begin
        mem[WRITE_ADDRESS] <= WRITE_VALUE;
    end
end

// Read from BRAM
reg [BRAM_ADD_WIDTH-1:0] BRAM_READ_ADDR = 14'b0;
always @(posedge BUS_CLK) begin
    BRAM_READ_VALUE <= mem[BRAM_READ_ADDR];
end
// 128'b11000011_00000000_11000011_00000000_11000011_00000000_11000011_00000000_11000011_00000000_11000011_00000000_11000011_00000000_11000011_00000000; 


// Choose BRAM Read Adr.
assign BUS_MEM_EN = (BUS_WR | BUS_RD) & (BUS_ADD >= REGSIZE);
assign BUS_MEM_ADD = BUS_ADD - REGSIZE;
always @(*) begin
    if (BUS_MEM_EN & !RECORDING) begin
        BRAM_READ_ADDR = BUS_MEM_ADD[BRAM_ADD_WIDTH+BLOCK_ADD_WIDTH-1:BLOCK_ADD_WIDTH]; // [18:4]
    end else begin
        BRAM_READ_ADDR = {CCOL_w, QROW_w};
    end
end

// wait for BRAM READ
reg PREV_EVENT_READY_r;
reg [BRAM_ADD_WIDTH-1:0] PREV_BRAM_WRITE_ADDR = 14'b0;
reg [15:0] PREV_HITMAP;
always @(posedge BUS_CLK) begin
    PREV_EVENT_READY_r <= EVENT_READY_r;
    PREV_BRAM_WRITE_ADDR <= BRAM_READ_ADDR;
    PREV_HITMAP <= HITMAP_w;
end

// WRITE TO BRAM
integer l;
always @(posedge BUS_CLK) begin
    if (RST) begin
        COUNTER <= 8'b0;
        WRITE_TOGGLE <= 1'b0;
    // Write via Bus
    end else if (BUS_MEM_EN && BUS_WR && !RECORDING) begin
        WRITE_TOGGLE <= 1'b1;
        WRITE_ADDRESS <= BUS_MEM_ADD[BRAM_ADD_WIDTH+BLOCK_ADD_WIDTH-1:BLOCK_ADD_WIDTH];
        WRITE_VALUE <= {16{BUS_DATA_IN}};
    // Write during recording
    end else if (RECORDING && PREV_EVENT_READY_r) begin 
        COUNTER <= COUNTER + 1;
        WRITE_TOGGLE <= 1'b1;
        WRITE_ADDRESS <= PREV_BRAM_WRITE_ADDR;
        for (l = 0; l < 16; l = l + 1) begin
            // if register of oen pixel reaches the maximum it stays there
            if(BRAM_READ_VALUE[BITS_PER_PIXEL*l +: BITS_PER_PIXEL] == 8'b1111_1111)
                WRITE_VALUE[BITS_PER_PIXEL*l +: BITS_PER_PIXEL] <= BRAM_READ_VALUE[BITS_PER_PIXEL*l +: BITS_PER_PIXEL];
            // otherwise increment
            else
                WRITE_VALUE[BITS_PER_PIXEL*l +: BITS_PER_PIXEL] <= BRAM_READ_VALUE[BITS_PER_PIXEL*l +: BITS_PER_PIXEL] + {7'b0, PREV_HITMAP[l]};
        end
    // close BRAM write
    end else begin
        WRITE_TOGGLE <= 1'b0;
    end
end

endmodule

// NOTE: Why is the read and write of the BRAM so complicated?
// Vivado will only translate mem to a BRAM (and not LUTs) when both the read as well as the write is only done each 
// at one position and only if this is done on clock. Thus, there is the need to do it in this more lengthy way.