/**
 * 第四版LCD完整连接层：545位UI快照与实际播放PCM输入，输出RGB666面板信号。
 * 内部统一使用clk_sys/rst_sys_n，lcd_clk仅作为面板输出时钟。
 * 显示ready在复位释放后寄存一拍，运行时不依赖面板绘制背压；PCM接收也不等待绘图。
 * 列缓存保持锁定直到drawers完成提交；扫描、PLL及面板默认时序沿用正式工程。
 */
module lcd_display
#(
    parameter CLK_SYS_HZ=98245614,
    parameter H_ACTIVE=800, parameter V_ACTIVE=480,
    parameter H_BACK=182, parameter H_FRONT=210,
    parameter V_BACK=8, parameter V_FRONT=45, parameter PIXEL_DIV=4
)(
    input wire clk_sys,input wire rst_n,
    input wire [544:0] display_in_state,input wire display_in_valid,output wire display_in_ready,
    input wire signed [15:0] audio_in,input wire audio_in_valid,output wire audio_in_ready,
    output wire lcd_clk,output wire lcd_en,output wire [5:0] lcd_r,output wire [5:0] lcd_g,output wire [5:0] lcd_b,
    output wire lcd_bl,output wire lcd_hs_n,output wire lcd_vs_n,
    output wire protocol_error,output wire configuration_error,output wire frame_active
);
    wire [544:0] scene_state;
    wire [21:0] highlight_mask,default_mask;
    wire scene_valid,scene_ready,render_done;
    wire wave_valid,spectrum_valid,pcm_valid,fft_overflow,spectrum_clipped;
    wire [15:0] peak,column_data;
    wire column_en;
    wire [10:0] column_addr;
    wire word_valid,word_ready,word_kind,present_valid,present_ready;
    wire [11:0] word_addr;
    wire [31:0] word_data;
    wire ui_error,draw_error,address_error,ui_config,driver_config;
    wire interaction_ready;
    // Break the reset/ready combinational path into the UI's wide display CE.
    // The receiver's readiness is configuration-only and cannot drop at run
    // time. Gate receiver valid with this same registered public ready.
    reg display_ready_r /* synthesis syn_preserve = 1 */;
    assign display_in_ready=display_ready_r;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if(!rst_n) display_ready_r<=1'b0;
        else display_ready_r<=interaction_ready;
    end
    assign protocol_error=ui_error || draw_error || address_error;
    assign configuration_error=ui_config || driver_config;
    ui_interaction #(.CLK_SYS_HZ(CLK_SYS_HZ), .WAVE_COLUMNS(576), .GRAPH_Y_MIN(88), .GRAPH_Y_MAX(327)) ui_interaction_u (
    .clk_sys(clk_sys),.rst_n(rst_n),.display_in_state(display_in_state),
    .display_in_valid(display_in_valid && display_ready_r),.display_in_ready(interaction_ready),
    .audio_in(audio_in),.audio_in_valid(audio_in_valid),.audio_in_ready(audio_in_ready),
    .scene_state(scene_state),.highlight_mask(highlight_mask),.default_mask(default_mask),
    .out_valid(scene_valid),.out_ready(scene_ready),.render_done(render_done),
    .scene_wave_valid(wave_valid),.scene_wave_seq(),.scene_output_peak(peak),.scene_pcm_valid(pcm_valid),
    .scene_spectrum_valid(spectrum_valid),.scene_spectrum_seq(),
    .scene_spectrum_clipped(spectrum_clipped),.scene_fft_overflow(fft_overflow),
    .scene_dropped_windows(),.column_rd_en(column_en),.column_rd_addr(column_addr),
    .column_rd_data(column_data),.dropped_windows(),.protocol_error(ui_error),.configuration_error(ui_config)
    );
    wire frame_tick;
    reg [15:0] frame_count_r;
    always @(posedge clk_sys or negedge rst_n)
    begin
        if (!rst_n) frame_count_r<=16'd0;
        else if (frame_tick) frame_count_r<=frame_count_r+16'd1;
    end
    drawers drawers_u (
    .frame_count(frame_count_r),
    .clk_sys(clk_sys),.rst_n(rst_n),.in_valid(scene_valid),.in_ready(scene_ready),
    .scene_state(scene_state),.highlight_mask(highlight_mask),.default_mask(default_mask),
    .scene_wave_valid(wave_valid),.scene_spectrum_valid(spectrum_valid),.scene_pcm_valid(pcm_valid),
    .scene_output_peak(peak),.scene_fft_overflow(fft_overflow),.scene_spectrum_clipped(spectrum_clipped),
    .column_rd_en(column_en),.column_rd_addr(column_addr),.column_rd_data(column_data),
    .word_valid(word_valid),.word_ready(word_ready),.word_kind(word_kind),.word_addr(word_addr),.word_data(word_data),
    .present_valid(present_valid),.present_ready(present_ready),.render_done(render_done),.protocol_error(draw_error)
    );
    lcd_driver #(.H_ACTIVE(H_ACTIVE),.V_ACTIVE(V_ACTIVE),.H_BACK(H_BACK),.H_FRONT(H_FRONT),
    .V_BACK(V_BACK),.V_FRONT(V_FRONT),.PIXEL_DIV(PIXEL_DIV)) lcd_driver_u (
    .clk(clk_sys),.rst_n(rst_n),.word_valid(word_valid),.word_ready(word_ready),
    .word_kind(word_kind),.word_addr(word_addr),.word_data(word_data),
    .present_valid(present_valid),.present_ready(present_ready),.frame_start(frame_tick),.frame_active(frame_active),
    .address_error(address_error),.configuration_error(driver_config),
    .lcd_clk(lcd_clk),.lcd_en(lcd_en),.lcd_r(lcd_r),.lcd_g(lcd_g),.lcd_b(lcd_b),
    .lcd_bl(lcd_bl),.lcd_hs_n(lcd_hs_n),.lcd_vs_n(lcd_vs_n)
    );
endmodule
