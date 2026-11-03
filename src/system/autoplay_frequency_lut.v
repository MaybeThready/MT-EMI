/** Shared 46..97 MIDI note to UQ16.16 Hz table for AutoPlay. */
module autoplay_frequency_lut(input [6:0] pitch, output reg [31:0] frequency);
    always @(*) begin
        case (pitch)
            7'd46: frequency = 32'd7637627;
            7'd47: frequency = 32'd8091784;
            7'd48: frequency = 32'd8572947;
            7'd49: frequency = 32'd9082720;
            7'd50: frequency = 32'd9622807;
            7'd51: frequency = 32'd10195009;
            7'd52: frequency = 32'd10801236;
            7'd53: frequency = 32'd11443511;
            7'd54: frequency = 32'd12123977;
            7'd55: frequency = 32'd12844906;
            7'd56: frequency = 32'd13608704;
            7'd57: frequency = 32'd14417920;
            7'd58: frequency = 32'd15275254;
            7'd59: frequency = 32'd16183568;
            7'd60: frequency = 32'd17145893;
            7'd61: frequency = 32'd18165441;
            7'd62: frequency = 32'd19245614;
            7'd63: frequency = 32'd20390018;
            7'd64: frequency = 32'd21602472;
            7'd65: frequency = 32'd22887021;
            7'd66: frequency = 32'd24247954;
            7'd67: frequency = 32'd25689813;
            7'd68: frequency = 32'd27217409;
            7'd69: frequency = 32'd28835840;
            7'd70: frequency = 32'd30550508;
            7'd71: frequency = 32'd32367136;
            7'd72: frequency = 32'd34291786;
            7'd73: frequency = 32'd36330882;
            7'd74: frequency = 32'd38491228;
            7'd75: frequency = 32'd40780036;
            7'd76: frequency = 32'd43204943;
            7'd77: frequency = 32'd45774043;
            7'd78: frequency = 32'd48495909;
            7'd79: frequency = 32'd51379626;
            7'd80: frequency = 32'd54434817;
            7'd81: frequency = 32'd57671680;
            7'd82: frequency = 32'd61101017;
            7'd83: frequency = 32'd64734272;
            7'd84: frequency = 32'd68583572;
            7'd85: frequency = 32'd72661764;
            7'd86: frequency = 32'd76982457;
            7'd87: frequency = 32'd81560072;
            7'd88: frequency = 32'd86409886;
            7'd89: frequency = 32'd91548086;
            7'd90: frequency = 32'd96991818;
            7'd91: frequency = 32'd102759252;
            7'd92: frequency = 32'd108869635;
            7'd93: frequency = 32'd115343360;
            7'd94: frequency = 32'd122202033;
            7'd95: frequency = 32'd129468544;
            7'd96: frequency = 32'd137167144;
            7'd97: frequency = 32'd145323527;
            default: frequency = 32'd0;
        endcase
    end
endmodule
