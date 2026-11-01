# 八旋钮驱动上板测试

工程：`test_knob_driver.gprj`；顶层：`test_knob_driver`；源码：`../../src/test/test_knob_driver.v`。

本工程验证PCB三片74HC165到原 `knob_driver`、原 `knob_event_handler` 的真实事件链，使用板载LED观察8个EC11的转动方向和按压。测试顶层不把旋钮事件当作持续电平重复执行；每次仅在 `valid && ready` 的系统时钟上升沿消费。旋钮参数到音色、ADSR和音量的映射继续由现有UI参数模块负责，本工程观察的是驱动和事件接口。

## 文件与仿真

- `../../src/test/test_knob_driver.v`：板载PLL包装顶层及可直接输入系统时钟的测试核心。
- `../../sim/tb/test/test_knob_driver_tb.vt`：24位165外设模型、8路动作与LED联调测试。
- `../../sim/do/common/compile_test_knob_driver.do`：复用原旋钮驱动编译列表。
- `../../sim/do/test/run_test_knob_driver.do`、`wave_test_knob_driver.do`：仿真入口和波形。
- 本目录中的GPRJ、CST、SDC、`build.tcl`：独立高云工程，所有共享路径均为相对路径。

在ModelSim中把当前目录切换到仓库的 `sim`，运行：

```tcl
do do/test/run_test_knob_driver.do
```

测试默认12kHz扫描和1ms按压/释放消抖，仅把事件指示灯缩短到4次扫描。覆盖上电已按住、8路位序、完整AB脉冲、正反转、短抖动、按住转动、多旋钮同帧动作、背压期间载荷保持和事件顺序、异步复位及恢复。正确时输出 `TEST_KNOB_DRIVER_PASS` 并在 `$stop` 停下。

原驱动的独立回归仍可运行：

```tcl
do do/driver/run_knob_driver.do
```

两套仿真使用各自的工作库和WLF文件。厂商PLL仅由上板包装层实例化；核心TB直接提供 `clk_sys`，不需要额外映射Gowin仿真库。

## 接线

板卡：Tang Mega 138K Pro，器件 `GW5AST-LV138FPG676AC1/I0`、Device Version C。FPGA引脚根据已有引脚分配指南核对，复位继续使用S0。

| 顶层信号 | FPGA位置 | 球位 | 旋钮PCB连接 |
| --- | --- | --- | --- |
| `clk_core` | 板载50MHz晶振 | P16 | 板内连接 |
| `rst_n` | S0 | K16 | 板内连接，按下复位 |
| `load_n` | 40P排针J23.1 | U16 | PCB J1.3，三片165的低有效 `/PL` |
| `shift_clk` | 40P排针J23.3 | U15 | PCB J1.5，三片165移位时钟 |
| `serial_data` | 40P排针J23.5 | W21 | PCB J1.7，165串行数据输出 |
| 3.3V供电 | J26.1或J26.2 | 电源 | PCB标为VCC/3.3V的电源端 |
| 共地 | J26.3/J26.4或J23.12 | 地 | PCB GND |

PCB供电使用3.3V；40P排针的J23.11是5V，不用它给本测试的旋钮板供电。数据、装载、移位时钟三根信号使用上述40P位置。电源和地按PCB丝印连接，不猜测未列出的PCB排针脚号。

本测试复用了先前键盘测试的J23.1/3/5位置；若键盘串行DATA还接在J23.5，请先拔下该根DATA，再接旋钮PCB J1.7，避免两个串行输出同时驱动同一个输入节点。

三片165的24位顺序是 `A8..A1、B8..B1、SW8..SW1`，每组bit0对应K1。软件默认SW原始低电平表示按下。

## LED含义与实测步骤

所有LED低电平亮。LED0、LED1、LED2的亮灯权值分别是1、2、4，相加再加1就是最近操作的旋钮编号：

| 最近操作 | LED0～LED2中亮起的灯 |
| --- | --- |
| K1 | 全灭 |
| K2 | LED0 |
| K3 | LED1 |
| K4 | LED0、LED1 |
| K5 | LED2 |
| K6 | LED0、LED2 |
| K7 | LED1、LED2 |
| K8 | LED0、LED1、LED2 |

| LED | 含义 |
| --- | --- |
| LED3 | 最近一次旋转方向：增加亮、减少灭；按压或松开不改变该方向显示 |
| LED4 | 至少一个旋钮处于已消抖按住状态 |
| LED5 | 每次转动一步、按下或松开时亮约200ms；FIFO溢出或扫描错误时锁存常亮 |

1. 下载后按下并松开S0。所有旋钮松开且不转动时，6个LED应全灭。K1编号恰好用全灭表示，需结合LED3/LED5判断动作，LED0不是心跳灯。
2. 分别慢转K1～K8。核对编号；正、反两个方向的LED3应相反，每个完整脉冲使LED5亮一次。快速连续转动会延长LED5亮起时间。
3. 分别按下K1～K8，编号应对应，LED4亮；松开后LED4灭。按住不动不应不断重触发事件，按住期间仍能转动。
4. 最后可同时操作两路。所有事件仍交付，LED编号显示同帧动作中编号较大的旋钮；LED3显示同帧最后处理的旋转方向。逐路核对时一次只操作一路更容易辨认。
5. 停止操作约300ms后LED5应灭；若仍常亮，表示 `overflow` 或 `scan_error` 已锁存，检查接线/扫描后按S0清除。

上电时已经按住的旋钮会正确显示保持状态，但不生成一次虚假的UI按压通知。

## EC11一步与方向参数

沿用已确认的“每完整脉冲一步”：`TRANSITIONS_PER_STEP=4`。默认增加方向的AB顺序为 `00 -> 01 -> 11 -> 10 -> 00`。15脉冲/圈不直接确定定位格数；若实际为30定位格，可能两格才对应一个完整脉冲，不能据此直接判定漏步。

实物顺时针若显示减少，在测试顶层的 `DIRECTION_INVERT` 中将对应位置1，例如仅反转K3设 `8'h04`，全部反转设 `8'hFF`。修改参数后重新构建位流即可，驱动接口不变。`TRANSITIONS_PER_STEP` 与UI波形切换累计参数 `WAVE_SELECT_STEPS` 含义不同。

## 高云工程构建与下载

1. 打开本目录的 `test_knob_driver.gprj`。
2. 将 `test_knob_driver` 设为顶层，Verilog标准设为SystemVerilog-2017；Include Path设为本目录相对路径 `../../src/system`。
3. 使用本目录的CST和SDC，器件选择上述138K Pro型号和版本C。
4. 运行Synthesize及Place & Route，检查错误和时序报告。
5. 在Gowin Programmer选择 `impl/pnr/test_knob_driver.fs`，执行SRAM Program，按S0后按前述步骤测试。

也可在本目录的PowerShell运行：

```powershell
& '<Gowin安装目录>/IDE/bin/gw_sh.exe' './build.tcl'
```

脚本设置顶层、标准、包含路径及布局布线选项，并检查本轮是否生成新位流，避免下载旧文件。现有PLL输出由Gowin自动建立时钟模型，业务逻辑仅在 `clk_sys` 上升沿运行，`scan_tick_up` 用作同步使能。

`impl`、`.gprj.user`、ModelSim工作库/WLF和本地 `modelsim.ini` 均属于生成物，不作为共享仿真配置。

## 本轮验证结果（2026-11-01）

- 原 `knob_driver_tb` 通过：52组事件、443次UI握手、518次串行扫描，包含FIFO满时的同时出入队；ModelSim为0错误、0警告。
- 新 `test_knob_driver_tb` 通过：829次串行扫描、743次UI交付、50组有序状态/动作检查，20步增加、10步减少、9次按下通知；ModelSim为0错误、0警告。
- 已生成 `impl/pnr/test_knob_driver.fs`，可用于SRAM上板测试。仿真验证数字逻辑，实物EC11方向和接线仍按上述步骤确认。

| 最差时序余量 | 结果 |
| --- | ---: |
| Setup | +2.717 ns |
| Hold | +0.147 ns |
| Recovery | +6.171 ns |
| Removal | +0.362 ns |
| Minimum Pulse Width | +1.202 ns |

建立、保持时间违例均为0。工程14个文件引用均存在，11位顶层IO各有唯一引脚约束。共享文本中不包含机器绝对路径；本轮仅新增测试文件和独立工程，没有Git提交。
