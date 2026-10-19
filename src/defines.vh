/**
 * 宏定义头文件
 */

 `ifndef PROJ_DEFINES
 `define PROJ_DEFINES

// 时钟频率与事件脉冲频率，单位均为 Hz
`define CLK_CORE_FREQ (50_000_000)
`define CLK_SYS_FREQ (98_304_000)
`define I2S_TICK_FREQ (1_536_000)
`define SMP_TICK_FREQ (48_000)
`define SCAN_TICK_FREQ (12_000)

// ADSR 包络除法延迟
`define ADSR_DIV_LATENCY (16)

`endif
