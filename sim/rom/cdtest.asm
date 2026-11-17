; savestate test program for the CD unit: ADPCM RAM writes and playback,
; a SCSI command waiting for its status, then data and status phases
; given by the testbench after the save point, CD interrupt flags, PSG.

lfsr	= $2002
sum	= $2005
tmp	= $2006
phase	= $2007
nrd	= $2008
cmdbuf	= $2010
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
	stz $2000
	tii $2000,$2001,$1FFF

	; ADPCM: reset, write address 0, 256 bytes of data
	lda #$80
	sta $180D
	stz $180D
	stz $1808
	stz $1809
	lda #$03
	sta $180D
	lda #$02
	sta $180D
	stz $180D
	ldx #0
.w:	txa
	eor #$5A
	sta $180A
.ww:	lda $180C
	and #$04
	bne .ww
	inx
	bne .w
	; read address 0, length 256, rate, play
	stz $1808
	stz $1809
	lda #$0C
	sta $180D
	lda #$08
	sta $180D
	stz $1808
	lda #$01
	sta $1809
	lda #$10
	sta $180D
	stz $180D
	lda #$0C
	sta $180E
	lda #$0C
	sta $1802
	lda #$20
	sta $180D

	; PSG channel 0
	lda #$FF
	sta $0801
	stz $0800
	lda #$40
	sta $0804
	stz $0804
	ldx #0
.wv:	txa
	and #$1F
	sta $0806
	inx
	cpx #32
	bne .wv
	lda #$80
	sta $0802
	lda #$01
	sta $0803
	lda #$FF
	sta $0805
	lda #$9F
	sta $0804

	; SCSI: READ6 lba 0x000010, 1 sector
	lda #$08
	sta cmdbuf
	stz cmdbuf+1
	stz cmdbuf+2
	lda #$10
	sta cmdbuf+3
	lda #$01
	sta cmdbuf+4
	stz cmdbuf+5
	jsr scsi_cmd

	lda #$A5
	sta lfsr

MAIN:
	lda lfsr
	asl a
	bcc .nx
	eor #$2D
.nx:	sta lfsr
	sta $0802
	; SCSI phases
	lda $1800
	sta phase
	and #$40
	beq .noreq
	lda phase
	and #$08
	beq .noreq
	; data in, status, message in: take the byte
	lda $1801
	ldx nrd
	sta buf,x
	inc nrd
	clc
	adc sum
	sta sum
	lda $1802
	ora #$80
	sta $1802
.wa:	lda $1800
	and #$40
	bne .wa
	lda $1802
	and #$7F
	sta $1802
.noreq:
	; ADPCM and CD flags
	lda $180C
	adc sum
	sta sum
	lda $1803
	adc sum
	sta sum
	lda $180A
	adc sum
	sta sum
	; restart ADPCM when it ends
	lda $180C
	and #$01
	beq MAIN
	stz $180D
	lda #$20
	sta $180D
	bra MAIN

scsi_cmd:
	lda #$81
	sta $1800
.wb:	lda $1800
	and #$80
	beq .wb
	ldx #0
.wr:	lda $1800
	and #$40
	beq .wr
	lda $1800
	and #$38
	cmp #$10
	bne .done
	lda cmdbuf,x
	sta $1801
	lda $1802
	ora #$80
	sta $1802
.wa:	lda $1800
	and #$40
	bne .wa
	lda $1802
	and #$7F
	sta $1802
	inx
	cpx #6
	bne .wr
.done:	rts

my_rti:	rti

	.org $FFF6
	.dw my_rti
	.dw my_rti
	.dw my_rti
	.dw my_rti
	.dw RESET
