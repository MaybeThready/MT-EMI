# 编译正式LCD频谱依赖，不引用历史文件或私有工作区路径。
# 仿真DO文件从正式sim目录执行；实现TCL由用户在工具中自行运行。
vlog -sv -work $SIM_LIB ../src/lcd_ui/lcd_fft_coeff_rom.v ../src/lcd_ui/lcd_fft1024.v ../src/lcd_ui/lcd_spectrum_builder.v
