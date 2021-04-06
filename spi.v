module`spi_ctlr(
//processor
pclk_i, prst_i, paddr_i, pwdata_i, prdata_o, pwrite_i, penable_i, pready_o, pslverr_o,
//SPI interface
sclk_ref_i, sclk, mosi, miso, cs
);
parameter MAX_TXS= 8;
parameter S_IDLE= 3'b000;
parameter S_ADDR= 3'b001;
parameter S_IDLE_BW_ADDR_DATA= 3'b010;
parameter S_DATA= 3'b011;
parameter S_IDLE_BW_TXS= 3'b100;

input pclk_i, prst_i, pwrite_i, penable_i;
input [7:0] paddr_i;
input [7:0] pwdata_i;
output reg [7:0] prdata_o;
output reg pready_o;
output reg pslverr_o;
input sclk_ref_i;
output reg sclk;
output reg mosi;
input miso;
output reg [3:0] cs;

//array of registers
reg [7:0] addr_regA[MAX_TXS-1:0];
reg [7:0] data_regA[MAX_TXS-1:0];
reg [7:0] ctrl_reg;
reg [2:0] state, next_state;
integer i;  //integer is same as reg [31:0]
reg sclk_running;
reg [7:0] addr_to_drive;
reg [7:0] data_to_drive;
reg [7:0] data_collected;
reg [3:0] total_txs;
reg [2:0] cur_tfr_idx;
integer count;


always @(sclk_ref_i) begin    //sclk_ref_i generated by processer this is contineusly running 
	if (sclk_running) begin
		sclk = sclk_ref_i; // iwant to run my sclk when transaction is happening
	end
	else begin
		sclk = 1;      // otherwise my sclk=1 forever
	end
end

always @(next_state) begin
	state = next_state; //state must be a reg variable
end

//two processes
//programming the registers : line number 57-85 is called procedural block. Code inside procedural block is called procedural statements.
always @(posedge pclk_i) begin
	if (prst_i == 1) begin
		//reset all the reg variables
		prdata_o = 0;
		pready_o = 0; //it is inside always block => hence it is a procedural statement => hence pready_o must be a reg
		pslverr_o = 0;
		addr_to_drive = 0;
		data_to_drive = 0;
		total_txs = 0;
		cur_tfr_idx = 0;
		for (i = 0; i < MAX_TXS; i=i+1) begin
			addr_regA[i] = 0;
			data_regA[i] = 0;
		end
		ctrl_reg = 0;
		mosi = 1;
		sclk = 1;
		sclk_running = 0;
		cs = 0;
		state = S_IDLE;
		next_state = S_IDLE;
	end
	else begin
		if (penable_i == 1) begin //penable_i is given by Processor
			pready_o = 1;  //SPI_CTLR
			if (pwrite_i == 1) begin
				if (paddr_i >= 8'h0 && paddr_i <= 8'h07) begin      //write to address_reg if range in 0 to 7
					addr_regA[paddr_i] = pwdata_i;
				end
				if (paddr_i >= 8'h10 && paddr_i <= 8'h17) begin   // write to data_reg renge in bitween 10 to 17
					data_regA[paddr_i-8'h10] = pwdata_i;   // 10-10=0 , 17-10=7 : because our pointer starts 0 to 7 only but our addris 10 to 17
				end
				if (paddr_i == 8'h20) begin
					ctrl_reg[3:0] = pwdata_i[3:0];       //write to ctrl_reg if range in bitween 8 to 10
					//ctrl_reg[7:4] are RO bits, which design will internally update, TB can't update
				end
			end
			else begin
				if (paddr_i >= 8'h0 && paddr_i <= 8'h07) begin   // read addr_reg if addr pointer in between 0 to 8
					prdata_o = addr_regA[paddr_i];
				end
				if (paddr_i >= 8'h10 && paddr_i <= 8'h17) begin  // read data_reg if it is in between range 10 to 17
					prdata_o = data_regA[paddr_i-8'h10];
				end
				if (paddr_i == 8'h20) begin
					prdata_o = ctrl_reg;      // read ctrl_reg if range in bitween 8 to 10
				end
			end
		end
	end
end

//2nd process
always @(posedge sclk_ref_i) begin
if (prst_i != 1) begin
case (state)
	S_IDLE: begin
		sclk_running = 0;
		if (ctrl_reg[0]) begin
			ctrl_reg[0] = 0;
			cur_tfr_idx = ctrl_reg[6:4]; //this address should drive
			total_txs = ctrl_reg[3:1] + 1;  //this TX should drive
			addr_to_drive = addr_regA[cur_tfr_idx];
			data_to_drive = data_regA[cur_tfr_idx];
			count = 0;
			next_state = S_ADDR;
		end
	end
	S_ADDR: begin
		sclk_running = 1;
		mosi = addr_to_drive[count];	//we want to write or read hole array
		count = count+1;         // increment sclk_ref_i count untill its 8
		if (count == 8) begin     //count =8 then only go to next state
			next_state = S_IDLE_BW_ADDR_DATA;
			count = 0;
		end
	end
	S_IDLE_BW_ADDR_DATA: begin
		sclk_running = 0;
		count = count+1;     // increment sclk_ref_i count untill its become 4
		if (count == 4) begin  // if count =4 then go next state                   //we are giving 4 clk cycle delay and start next state
			next_state = S_DATA;
			count = 0;
		end
	end
	S_DATA: begin
		sclk_running = 1;
		if (addr_to_drive[7] == 1) mosi = data_to_drive[count];	//if 7th bit 1 then wr_data
		else data_collected[count] = miso;	//if 7th bit data is 0 then read from slave
		count = count+1;
		if (count == 8) begin
			total_txs = total_txs - 1;  //we write 1 transfers then we reduce one address
			cur_tfr_idx = cur_tfr_idx + 1; // increse pointer and write other one adress
			ctrl_reg[6:4] = cur_tfr_idx;  //go here and check next address.
			addr_to_drive = 0;
			data_to_drive = 0;
			if (total_txs == 0) begin      //if all txs is done then go to ideal state
				next_state = S_IDLE; 
			end
			else begin
				next_state = S_IDLE_BW_TXS;  // if there any transfer pending
			end
			count = 0;
		end
	end
	S_IDLE_BW_TXS: begin
		sclk_running = 0;
		count = count+1;
		if (count == 8) begin                               //waiting 8 clk cycle for getting if there any other transaction happens
			addr_to_drive = addr_regA[cur_tfr_idx];
			data_to_drive = data_regA[cur_tfr_idx];
			next_state = S_ADDR;
			count = 0;
		end
	end
endcase
end
end
endmodule