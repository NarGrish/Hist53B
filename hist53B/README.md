## HIST53B

Histogramming of Pixelhits on the BDAQ53B

# Description:

To reduce the amount of dataflow between the BDAQ53B and the Computer, HIST53B offers the ability to create a histogram of Pixelhits on the FPGA. The main usecase for such histograms are bump-connectivity scans.

# Operation:

The HIST53B is controled via the python-functions implemented in "hist53B.py". To start the scan "RECORDING" is set to 1. HIST53B will record hits until "RECORDING" is set back to 0. Afterwards the BRAM can be read out and result can be displayed using the python script. The typical sequence of function calls will be:

1. start_recording()
2. Do your testing
3. stop_recording()
4. data = get_data()
5. result = depict_data(data)

# Configuration

To use HIST53B properly you will need to check the following configurations:
- Turn ON "Drop-Tot" (ToT-values are of no use for this)
- Turn ON "raw map" (Only works with the raw 16 bit Hitmap)
- Only use ONE Chip at a time (there is not enough for 2 chips at a time)
- You are allowed to use End of Stream markers

# Test modus

During code writing test-functions were implemted to test the underlying functions of the mudule without the usage of AURORA-Simulations. In the test mode registers simulate the incoming dataflow and are set via additional python-functions. In order to use the Test-mode write HITMAP, QROW and Flag-Bits in the corresponding registers. THEN set test_toggle to 1 and Ccol to a valid value. Afterwards set test_toggle back to 0. The corresponding memory location will be incremented according to the hitmap. You can now read out the memory or test an additional set of values.

## Still open ToDo

The major one beeing:
- Finding a way to really Drop ToT (currently not running in Simulation)
- Get the RAM working again in Synthesis (currently not working any more), incl initial values
Smaller Things:
- implement a marker for full FIFO
- Test the read function after fixing the Drop ToT
- Only FIFO read if recording?