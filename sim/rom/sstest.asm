; savestate test program: VDC (BG, sprites, raster IRQ, SATB and VRAM DMA),
; timer IRQ, PSG (waveforms, DDA, noise, LFO), VCE writes, block transfers,
; bank switching and VRAM reads.

frame	= $2000
tcnt	= $2001
lfsr	= $2002
vreg	= $2004
sum	= $2005
tmp	= $2006
rcr	= $2008
satb	= $2200
buf	= $2400

	.bank 0
	.org $E000

RESET:
	sei
	csh
	cld
	ldx #$FF
	txs
	lda #$FF
	tam #0
	lda #$F8
	tam #1
	lda #$07
	sta $1402
	sta $1403
	stz $0C01
	stz $2000
	tii $2000,$2001,$1FFF

	ldx #0
.vl:	lda vdc_tab,x
	bmi .vend
	sta $0000
	lda vdc_tab+1,x
	sta $0002
	lda vdc_tab+2,x
	sta $0003
	inx
	inx
	inx
	bra .vl
.vend:
	lda #$04
	sta $0400

	stz $0402
	stz $0403
	ldx #0
.pl:	lda pal_tab,x
	sta $0404
	lda pal_tab+1,x
	sta $0405
	inx
	inx
	cpx #64
	bne .pl
	stz $0402
	lda #1
	sta $0403
	ldx #0
.pl2:	lda pal_tab+1,x
	sta $0404
	lda pal_tab,x
	sta $0405
	inx
	inx
	cpx #64
	bne .pl2

	; BAT at $0000, 32x32
	st0 #0
	st1 #0
	st2 #0
	st0 #2
	ldy #0
	ldx #0
.bat:	txa
	and #3
	sta $0002
	txa
	and #$30
	ora #$01
	sta $0003
	inx
	bne .bat
	iny
	cpy #4
	bne .bat

	; tiles at $1000 (tiles $100..$103), sprite pattern at $2000
	st0 #0
	st1 #$00
	st2 #$10
	st0 #2
	tia tile_gfx,$0002,128
	st0 #0
	st1 #$00
	st2 #$20
	st0 #2
	tia spr_gfx,$0002,128

	; SATB: 24 sprites
	ldx #0
	ldy #0
.sat:	tya
	asl a
	asl a
	asl a
	adc #64
	sta satb,x
	stz satb+1,x
	tya
	asl a
	asl a
	asl a
	asl a
	adc #32
	sta satb+2,x
	stz satb+3,x
	lda #$00
	sta satb+4,x
	lda #$01
	sta satb+5,x
	tya
	and #$0F
	sta satb+6,x
	stz satb+7,x
	txa
	clc
	adc #8
	tax
	iny
	cpy #24
	bne .sat

	; PSG
	lda #$FF
	sta $0801
	lda #0
	jsr psg_wave
	lda #1
	jsr psg_wave
	lda #4
	sta $0800
	lda #$9C
	sta $0804
	lda #$FF
	sta $0805
	lda #$85
	sta $0807
	lda #2
	sta $0800
	lda #$DF
	sta $0804
	lda #$FF
	sta $0805
	lda #$20
	sta $0808
	lda #$01
	sta $0809

	; timer
	lda #$10
	sta $0C00
	lda #1
	sta $0C01

	lda #$A5
	sta lfsr
	lda #$5A
	sta lfsr+1
	lda #64
	sta rcr

	lda #$01
	sta $1402
	lda #5
	sta vreg
	st0 #5
	st1 #$CC
	st2 #$00
	cli

MAIN:
	; LFSR
	lda lfsr
	asl a
	rol lfsr+1
	bcc .nx
	eor #$2D
.nx:	sta lfsr
	ldx lfsr
	sta buf,x
	; bank switch and read ROM through MPR2
	lda #0
	tam #2
	lda $5000,x
	clc
	adc sum
	sta sum
	; block moves in RAM
	tii buf,buf+$100,$C0
	tdd buf+$1FF,buf+$2FF,$40
	; VRAM read through MARR/VRR
	sei
	lda #1
	sta vreg
	st0 #1
	stx $0002
	st2 #$10
	lda #2
	sta vreg
	st0 #2
	lda $0002
	adc $0003
	cli
	adc sum
	sta sum
	; T flag operation on $2040
	ldx #$40
	set
	adc #3
	sxy
	sax
	bra MAIN

psg_wave:
	sta $0800
	lda #$40
	sta $0804
	stz $0804
	ldx #0
.w:	lda wave_tab,x
	sta $0806
	inx
	cpx #32
	bne .w
	lda #$80
	sta $0802
	lda #$01
	sta $0803
	lda #$FF
	sta $0805
	lda #$9F
	sta $0804
	rts

vdc_int:
	pha
	phx
	phy
	lda $0000
	sta tmp
	and #$04
	beq .novr
	; raster: scroll the lower part
	lda #7
	sta $0000
	lda frame
	asl a
	sta $0002
	stz $0003
.novr:	lda tmp
	and #$20
	bne .vbl
	jmp .exit
.vbl:	inc frame
	; move sprites
	ldx #0
.mv:	lda satb+2,x
	clc
	adc #1
	sta satb+2,x
	txa
	clc
	adc #8
	tax
	cpx #192
	bne .mv
	; SATB copy to VRAM $7F00 and DMA request
	lda #0
	sta $0000
	st1 #$00
	st2 #$7F
	st0 #2
	tia satb,$0002,192
	st0 #$13
	st1 #$00
	st2 #$7F
	; VRAM-VRAM DMA every 4 frames
	lda frame
	and #3
	bne .nodma
	st0 #$0F
	st1 #$12
	st2 #$00
	st0 #$10
	st1 #$00
	st2 #$10
	st0 #$11
	st1 #$00
	st2 #$30
	st0 #$12
	st1 #$7F
	st2 #$00
.nodma:
	; raster line
	lda frame
	and #63
	clc
	adc #80
	sta rcr
	st0 #6
	sta $0002
	st2 #0
	; BYR
	st0 #8
	lda frame
	sta $0002
	st2 #0
	; colour cycling
	stz $0402
	stz $0403
	lda frame
	sta $0404
	stz $0405
	; PSG ch0 frequency
	lda #0
	sta $0800
	lda frame
	sta $0802
	lda #1
	sta $0803
.exit:	lda vreg
	sta $0000
	ply
	plx
	pla
	rti

timer_int:
	sta $1403
	pha
	inc tcnt
	lda #3
	sta $0800
	lda #$DF
	sta $0804
	lda tcnt
	and #$1F
	sta $0806
	pla
my_rti:	rti

vdc_tab:
	.db $06,$40,$00
	.db $07,$00,$00
	.db $08,$00,$00
	.db $09,$00,$00
	.db $0A,$02,$02
	.db $0B,$1F,$04
	.db $0C,$07,$0D
	.db $0D,$DF,$00
	.db $0E,$03,$00
	.db $0F,$10,$00
	.db $13,$00,$7F
	.db $FF

pal_tab:
	.dw $000,$007,$038,$03F,$1C0,$1C7,$1F8,$1FF
	.dw $049,$092,$0DB,$124,$16D,$1B6,$1A4,$0A4
	.dw $111,$022,$033,$044,$055,$066,$077,$088
	.dw $099,$0AA,$0BB,$0CC,$0DD,$0EE,$0FF,$100

wave_tab:
	.db 0,3,6,9,12,15,18,21,24,27,30,31,29,26,23,20
	.db 17,14,11,8,5,2,1,4,7,10,13,16,19,22,25,28

tile_gfx:
	.db $FF,$00,$81,$7E,$BD,$42,$A5,$5A,$A5,$5A,$BD,$42,$81,$7E,$FF,$00
	.db $00,$FF,$7E,$81,$42,$BD,$5A,$A5,$5A,$A5,$42,$BD,$7E,$81,$00,$FF
	.db $AA,$55,$55,$AA,$AA,$55,$55,$AA,$AA,$55,$55,$AA,$AA,$55,$55,$AA
	.db $F0,$0F,$F0,$0F,$F0,$0F,$F0,$0F,$0F,$F0,$0F,$F0,$0F,$F0,$0F,$F0
	.db $11,$22,$33,$44,$55,$66,$77,$88,$99,$AA,$BB,$CC,$DD,$EE,$FF,$00
	.db $01,$02,$04,$08,$10,$20,$40,$80,$80,$40,$20,$10,$08,$04,$02,$01
	.db $C3,$3C,$C3,$3C,$C3,$3C,$C3,$3C,$C3,$3C,$C3,$3C,$C3,$3C,$C3,$3C
	.db $E7,$18,$E7,$18,$E7,$18,$E7,$18,$E7,$18,$E7,$18,$E7,$18,$E7,$18

spr_gfx:
	.db $FF,$FF,$81,$81,$81,$81,$81,$81,$81,$81,$81,$81,$81,$81,$FF,$FF
	.db $FF,$FF,$C3,$C3,$A5,$A5,$99,$99,$99,$99,$A5,$A5,$C3,$C3,$FF,$FF
	.db $00,$00,$3C,$3C,$7E,$7E,$FF,$FF,$FF,$FF,$7E,$7E,$3C,$3C,$00,$00
	.db $18,$18,$3C,$3C,$7E,$7E,$FF,$FF,$FF,$FF,$7E,$7E,$3C,$3C,$18,$18
	.db $AA,$AA,$55,$55,$AA,$AA,$55,$55,$AA,$AA,$55,$55,$AA,$AA,$55,$55
	.db $0F,$0F,$0F,$0F,$F0,$F0,$F0,$F0,$0F,$0F,$0F,$0F,$F0,$F0,$F0,$F0
	.db $01,$01,$03,$03,$07,$07,$0F,$0F,$1F,$1F,$3F,$3F,$7F,$7F,$FF,$FF
	.db $80,$80,$C0,$C0,$E0,$E0,$F0,$F0,$F8,$F8,$FC,$FC,$FE,$FE,$FF,$FF

	.org $FFF6
	.dw my_rti
	.dw vdc_int
	.dw timer_int
	.dw my_rti
	.dw RESET
