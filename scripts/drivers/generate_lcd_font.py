"""Generate an original compact 5x7 alphabet in 8x16 cells, one real SDPB ROM.
Rows below are hand-authored binary glyphs; lower-case uses the upper-case glyph.
Control codes/space are blank; unsupported printable characters use '?'.
Outputs embed initialization in RTL, so delivery has no runtime font-file path.
"""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
patterns = {
'A':'0E11111F111111','B':'1E11111E11111E','C':'0E11101010110E','D':'1E11111111111E',
'E':'1F10101E10101F','F':'1F10101E101010','G':'0E11101711110F','H':'1111111F111111',
'I':'0E04040404040E','J':'0702020212120C','K':'11121418141211','L':'1010101010101F',
'M':'111B1515111111','N':'11191513111111','O':'0E11111111110E','P':'1E11111E101010',
'Q':'0E11111115120D','R':'1E11111E141211','S':'0F10100E01011E','T':'1F040404040404',
'U':'1111111111110E','V':'11111111110A04','W':'11111115151B11','X':'11110A040A1111',
'Y':'11110A04040404','Z':'1F01020408101F',
'0':'0E11131519110E','1':'040C040404040E','2':'0E11010204081F','3':'1E01010601011E',
'4':'02060A121F0202','5':'1F10101E01011E','6':'0E10101E11110E','7':'1F010204080808',
'8':'0E11110E11110E','9':'0E11110F01010E',
'?':'0E110102040004','!':'04040404040004','-':'0000001F000000','+':'0004041F040400',
'.':'00000000000004',':':'00040000040000','/':'01010204081010','%':'19190204081313',
'=':'00001F001F0000','_':'0000000000001F','(':'02040808080402',')':'08040202020408',
'[':'0E08080808080E',']':'0E02020202020E','<':'02040810080402','>':'08040201020408',
'*':'00150E1F0E1500',',':'00000000000408',"'":'04040800000000','"':'0A0A1400000000',
'#':'0A0A1F0A1F0A0A','|':'04040404040404','\\':'10100804020101',
';':'00040000040408','@':'0E11171516100F','$':'040F140E051E04','&':'0C12140C15120D',
'^':'040A1100000000','`':'08040200000000','{':'02040408040402','}':'08040402040408',
'~':'00000916000000'
}
data=[]
for code in range(128):
    char=chr(code).upper()
    rows=bytes.fromhex(patterns.get(char,patterns['?'])) if code>32 and code!=127 else bytes(7)
    data += [0]+[r<<2 for r in rows for _ in range(2)]+[0]
assert len(data)==2048
params=[f"        .INIT_RAM_{i:02X}(256'h{int.from_bytes(bytes(data[i*32:(i+1)*32]),'little'):064x})" for i in range(64)]
rtl='''/**
 * Original fixed 8x16 ASCII font, one 2048x8 GW5A SDPB initialized ROM.
 * Lowercase has uppercase shapes; no Chinese. Hand-authored 5x7 shapes are
 * doubled vertically, not a system-font dependency. MSB is left pixel.
 * One synchronous read, clk_sys/rst_sys_n. No Q format.
 * Reproduce with scripts/drivers/generate_lcd_font.py.
 */
module lcd_font_rom
(
    input clk,
    input rst_n,
    input [6:0] ascii_code,
    input [3:0] glyph_y,
    output [7:0] glyph_row
);
    wire [31:0] rom_data;
    assign glyph_row = rom_data[7:0];
    SDPB #(
        .READ_MODE(1'b0), .BIT_WIDTH_0(8), .BIT_WIDTH_1(8),
        .RESET_MODE("ASYNC"), .BLK_SEL_0(3'b000), .BLK_SEL_1(3'b000),
'''+',\n'.join(params)+'''
    ) sdpb_u (
        .CLKA(clk), .CLKB(clk), .CEA(1'b0), .CEB(rst_n), .OCE(1'b1),
        .RESET(!rst_n), .BLKSELA(3'b000), .BLKSELB(3'b000),
        .ADA(14'd0), .ADB({ascii_code, glyph_y, 3'b000}), .DI(32'd0), .DO(rom_data)
    );
endmodule
'''
(ROOT/'src/drivers/lcd_font_rom.v').write_text(rtl,encoding='utf-8')
(ROOT/'assets/drivers').mkdir(exist_ok=True)
(ROOT/'assets/drivers/lcd_font.hex').write_text(''.join(f'{v:02x}\n' for v in data),encoding='ascii')
print('Generated 128 glyphs; one 16-Kbit SDPB ROM, all contents embedded in RTL.')
