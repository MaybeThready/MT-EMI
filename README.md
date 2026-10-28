# MT-EMI

2026.10.22 最后一次修订

## 1. 项目概述

MT-EMI，Multi-Timbre Electronic Musical Instrument，多音色电子乐器。该项目是一个基于 FPGA 的电子乐器开发计划，旨在实现多音色、多效果的电子音乐演奏功能。

该项目的文件组织架构如下

```txt
MT-EMI
├─ assets  // 资源文件夹，存放 ROM 查找表等
├─ docs  // 文档文件夹，存放项目说明、开发指南等
│  ├─ S1开发计划.md
│  ├─ UI交互设计.md
│  ├─ 常用模块使用指南.md
│  ├─ 项目代码开发规范.md
│  └─ 项目合作开发规范.md
├─ MT-EMI.gprj  // Gowin 项目文件
├─ README.md
├─ scripts  // 脚本文件夹，存放辅助脚本，比如生成 ROM 查找表的 Python 脚本
├─ sim  // 仿真文件夹，存放仿真相关文件
│  ├─ do  // 按 TB 组织的 ModelSim 仿真入口、公共编译依赖和波形配置
│  └─ tb  // Testbench 文件夹，按 audio、system 分类
└─ src  // RTL 源码文件夹，存放 Verilog 源码
   ├─ audio
   ├─ adsr_division
   ├─ common
   │  ├─ clock_divider.v
   │  └─ fsm.v
   ├─ defines.vh
   ├─ fixed_points
   │  ├─ signed_fp_norm.v
   │  ├─ signed_fp_op.v
   │  ├─ unsigned_fp_norm.v
   │  └─ unsigned_fp_op.v
   ├─ gowin_pll
   │  ├─ gowin_pll.ipc
   │  ├─ gowin_pll.v
   │  └─ gowin_pll_mod.v
   ├─ MT-EMI.sdc
   ├─ pll_init.v
   ├─ signal_detection
   │  ├─ signal_edge_detector.v
   │  └─ signal_sync.v
   ├─ system
   └─ top.v
```

该 README 文件需要在最终阶段完成后进行补充，包含项目概述、文件组织架构、开发环境、编译与仿真流程、使用说明等内容。
