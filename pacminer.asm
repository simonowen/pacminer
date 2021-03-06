; Pac-Man hardware emulation for the Sinclair ZX Spectrum (v1.3)
;
; http://simonowen.com/spectrum/pacemuzx/

debug:         equ 0                ; non-zero for border stripes showing CPU use

; Memory maps
;
; Loading (normal paging R/5/2/0):
; a000-afff - emulation code
; b000-bfff - unshifted tiles+sprites
; c000-ffff - 16K Pac-Man ROM
;
; Emulation (special paging 0/1/2/3):
; 0000-3fff - 16K Pac-Man ROM
; 4000-50ff - Pac-Man display, I/O and working RAM
; 5100-7fff - unused
; 8000-9fff - 2nd half of sprite data
; a000-afff - emulation code
; b000-bfff - look-up tables
; c000-dfff - 8K sound table
; e000-ffff - first 8K of Pac-Man ROM (unpatched)
;
; Graphics (normal paging R3/5/2/7):
; 0000-3fff - Spectrum 48K ROM
; 4000-5aff - Spectrum display (normal)
; 5b00-5bef - screen data behind sprites (normal)
; 5bf0-9fff - pre-rotated sprite graphics
; a000-afff - emulation code
; b000-bfff - look-up tables
; c000-daff - Spectrum display (alt)
; db00-dbef - screen data behind sprites (alt)
; dbf0-ffff - pre-rotated tile graphics

screen_attr:   equ &07              ; white on black

kempston:      equ 31               ; Kempston joystick in bits 4-0
divide:        equ 227              ; DivIDE interface
border:        equ 254              ; Border colour in bits 2-0
keyboard:      equ 254              ; Keyboard matrix in bits 4-0

pac_footer:    equ &4000            ; credit and fruit display
pac_chars:     equ &4040            ; start of main Pac-Man display (skipping the score rows)
pac_header:    equ &43c0            ; 64 bytes containing the score

; address of saved sprite block followed by the data itself
spr_save_2:    equ &5b00
spr_save_3:    equ spr_save_2+2+2+(3*12)   ; attr address, data address, 3 bytes * 12 lines
spr_save_4:    equ spr_save_3+2+2+(3*12)
spr_save_5:    equ spr_save_4+2+2+(3*12)
spr_save_6:    equ spr_save_5+2+2+(3*12)
spr_save_7:    equ spr_save_6+2+2+(3*12)
spr_save_end:  equ spr_save_7+2+2+(3*12)

; pre-shifted sprite graphics
spr_data_0:    equ spr_save_end
spr_data_1:    equ spr_data_0 + (76*2*12)  ; 11111111 11110000
spr_data_2:    equ spr_data_1 + (76*2*12)  ; 01111111 11111000
spr_data_3:    equ spr_data_2 + (76*2*12)  ; 00111111 11111100
spr_data_4:    equ spr_data_3 + (76*2*12)  ; 00011111 11111110
spr_data_5:    equ spr_data_4 + (76*2*12)  ; 00001111 11111111
spr_data_6:    equ spr_data_5 + (76*3*12)  ; 00000111 11111111 10000000
spr_data_7:    equ spr_data_6 + (76*3*12)  ; 00000011 11111111 11000000
spr_data_end:  equ spr_data_7 + (76*3*12)  ; 00000001 11111111 11100000

; pre-shifted tile graphics
tile_data_0:   equ &8000 + spr_data_0
tile_data_6:   equ tile_data_0 + (192*1*6) ; 11111100
tile_data_4:   equ tile_data_6 + (192*2*6) ; 00000011 11110000
tile_data_2:   equ tile_data_4 + (192*2*6) ;          00001111 11000000
end_tile_data: equ tile_data_2 + (192*1*6) ;                   00111111

; sound look-up table
sound_table:   equ &c000


MACRO set_border, bordcol
IF debug
    ld a,bordcol
    out (border),a
ENDIF
ENDM

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

               org &a000
start:         jr  start2

; Dips at fixed address for easy poking
dip_5000:      defb %11111111       ; c21tdrlu     c=credit, 2=coin2, 1=coin1, t=rack test on/off ; down, right, left, up
                                    ; default: rack test off, nothing else signalled
dip_5040:      defb %11111111       ; c--sdrlu     c=cocktail/upright ; s=service mode on/off ; down, right, left, up (player 2)
                                    ; default: upright mode, service mode off, no controls pressed
dip_5080:      defb %11001001       ; -dbbllcc      d=hard/normal bb=bonus life at 10K/15K/20K/none ; ll=1/2/3/5 lives ; cc=freeplay/1coin1credit/1coin2credits/2coins1credit
                                    ; default: normal, bonus life at 10K, 3 lives, 1 coin 1 credit

start2:        di

               ld  hl,loading_msg
               call print_msg

               ld  a,(&5b5c)        ; sysvar holding 128K paging
               ex  af,af'           ; keep safe
               ld  a,%00000001      ; special paging, banks 0/1/2/3
               ld  bc,&1ffd         ; +3 paging port
               out (c),a            ; attempt paging
               ld  a,(3)            ; peek value in Pac-Man ROM
               and a                ; zero?
               jr  z,start3         ; if so, start up

               ex  af,af'
               out (c),a            ; restore 128K paging (disturbed due to partial address decoding)
               ei

               ld  hl,plus2a3_msg
               jp  print_msg

; Next, move any data from load position to final location
start3:        ld  sp,new_stack

               ld  hl,&0000
               ld  de,&e000
               ld  bc,&2000
               ldir                 ; copy 8K of ROM to &e000 (start of page 3)

               ld  a,&01            ; to change &5000 write to &5001, which is unused
               ld  (&0071),a
               xor a                ; patch OUT (0),A to be NOP;NOP
               ld  (&0109),a

               ld  hl,(&0039)       ; original interrupt handler
               ld  (int_chain+1),hl
               ld  hl,do_int_hook   ; our interrupt handler hook
               ld  (&0039),hl

               ld  a,%00000100      ; +3 normal paging
               ld  bc,&1ffd
               out (c),a            ; restore R3/5/2/0, for ROM access at &c000


               call chk_specnet     ; check if Spectranet traps are enabled
               jr  z,no_specnet     ; skip forwards if not

               ld  hl,specnet_msg   ; prompt to disable traps
               call print_msg

wait_specnet:  ld  bc,0             ; delay roughly half a second
delay:         djnz $
               djnz $
               dec c
               jr  nz,delay

               call chk_specnet     ; check traps again
               jr  nz,wait_specnet  ; jump back if they're still enabled
no_specnet:

               ld  a,%10000011      ; DivIDE page 3
               out (divide),a       ; page in at &2000, if present

               ld  hl,&c000
               ld  de,&2000
               ld  bc,&2000
               ldir                 ; copy first 8K of ROM to DivIDE page 3

               ld  a,%10000000      ; DivIDE page 0
               out (divide),a       ; page in at &2000, if present

               ld  de,&2000
               ld  bc,&2000
               ldir                 ; copy last 8K of ROM to DivIDE page 0

               ld  a,%01000000      ; MAPRAM
               out (divide),a       ; page 3 at &0000 (read-only), page 0 at &2000

               ld  a,(scr_page)     ; normal display, page 7
               ld  bc,&7ffd
               out (c),a            ; page 7 at &c000
               ld  ixh,&80          ; write to alt screen

               ld  hl,load_tiles
               ld  de,tile_data_0
               ld  bc,&0480
               ldir                 ; copy unshifted tile data

               ld  hl,load_sprites
               ld  de,spr_data_0
               ld  bc,&0720
               ldir                 ; copy unshifted sprite data

               call make_tables     ; create all the look-up tables and pre-shift sprites
               call page_rom        ; page in sound table and ROM
               call sound_init      ; enable sound chip
               call init_screens    ; prepare both screens and sprite save areas

               ld  hl,&5000         ; Pac-Man I/O area
               xor a
clear_io:      ld  (hl),a           ; zero fill it
               inc l
               jr  nz,clear_io

               ld  a,(dip_5000)     ; set hardware dips to our defaults
               ld  (&5000),a
               ld  a,(dip_5040)
               ld  (&5040),a

               ld  a,&bf
               in  a,(keyboard)
               bit 4,a              ; Z if H pressed

               ld  a,(dip_5080)
               jr  nz,not_hard
               and %10111111        ; set Hard difficulty
not_hard:      ld  (&5080),a

               ld  sp,&4c00         ; stack in spare RAM
               jp  0                ; start the ROM!  (and page in DivIDE, if present)

page_rom:      push af
               push bc
               ld  a,%00000001      ; +3 special paging, banks 0/1/2/3
               ld  bc,&1ffd
               out (c),a
               pop bc
               pop af
               ret

page_screen:   push af
               push bc
               ld  a,%00000100      ; +3 normal paging, R3/5/2/7
               ld  bc,&1ffd
               out (c),a
               pop bc
               pop af
               ret


; Do everything we need to update video/sound/input
;
do_int_hook:   ld  (old_stack+1),sp
               ld  sp,new_stack

               push af
               push bc
               push de
               push hl
               ex  af,af'
               push af
               exx
               push bc
               push de
               push hl
               push ix

               call do_flip         ; show last frame, page in new one

               ld  hl,&5062         ; sprite 1 x
               inc (hl)             ; offset 1 pixel left (mirrored)
               ld  hl,&5064         ; sprite 2 x
               inc (hl)

set_border 1
               call do_restore      ; restore under the old sprites
set_border 2
               call do_tiles        ; update a portion of the background tiles
set_border 3
               call do_input        ; scan the joystick and DIP switches
set_border 4
               call do_sound        ; convert the sound to the AY chip
set_border 5
               call do_save         ; save under the new sprite positions
set_border 6
               call do_sprites      ; draw the 6 new masked sprites
set_border 0

               ld  hl,&5062         ; sprite 1 x
               dec (hl)             ; reverse change from above
               ld  hl,&5064         ; sprite 2 x
               dec (hl)

               pop ix
               pop hl
               pop de
               pop bc
               exx
               pop af
               ex  af,af'
               pop hl
               pop de
               pop bc
               pop af

old_stack:     ld  sp,0             ; self-modified by code above
int_chain:     jp  0                ; original RAM handler address


; Flip to show the screen prepared during the last frame, and prepare to draw the next
;
do_flip:       push af
               push bc

               ld  a,(scr_page)     ; current screen
               xor %00001000        ; toggle active screen bit
               ld  (scr_page),a
               ld  bc,&7ffd
               out (c),a            ; activate

               sub %00001000        ; set carry if we're viewing the normal screen
               ld  a,0
               rra
               ld  ixh,a            ; b7 holds b15 of drawing screen address

               pop bc
               pop af
               ret

scr_page:      defb %00000111       ; normal screen (page 5), page 7 at &c000


; Scan the input DIP switches for joystick movement and button presses
;
do_input:      ld  de,&ffff         ; nothing pressed

               ld  a,&f7
               in  a,(keyboard)
               cpl
               and %00000111
               jr  z,not_123
               rra
               jr  nc,not_1
               res 5,e              ; 1 = start 1
not_1:         rra
               jr  nc,not_2
               res 6,e              ; 2 = start 2
not_2:         rra
               jr  nc,not_123
               res 5,d              ; 3 = coin 1
not_123:

               ld  a,&fe
               in  a,(keyboard)
               rra
               jr  c,no_shift

               ld  a,&fb
               in  a,(keyboard)
               bit 4,a
               jr  nz,not_shift_t
               res 4,d              ; shift-t = rack test
not_shift_t:

; Shifted for Cursor keys
               ld  a,&f7
               in  a,(keyboard)
               bit 4,a
               jr  nz,not_shift_5
               res 1,d              ; Shift-5 = left
not_shift_5:
               ld  a,&ef
               in  a,(keyboard)
               cpl
               and %00011100
               jr  z,read_joy
               rra
               rra
               rra
               jr  nc,not_shift_8
               res 2,d              ; Shift-8 = right
not_shift_8:   rra
               jr  nc,not_shift_7
               res 0,d              ; Shift-7 = up
not_shift_7:   rra
               jr  nc,read_qaop
               res 3,d              ; Shift-6 = down
               jr  read_qaop

; Unshifted for Sinclair joystick
no_shift:      ld  a,&ef
               in  a,(keyboard)
               cpl
               and %00011111
               jr  z,not_67890
               rra
               jr  nc,not_0
               res 2,e              ; 0 = right 2 (jump)
not_0:         rra
               jr  nc,not_9
               res 0,d              ; 9 = up
not_9:         rra
               jr  nc,not_8
               res 3,d              ; 8 = down
not_8:         rra
               jr  nc,not_7
               res 2,d              ; 7 = right
not_7:         rra
               jr  nc,not_67890
               res 1,d              ; 6 = left
not_67890:

read_qaop:     ld  a,&fb
               in  a,(keyboard)
               rra
               jr  c,not_q
               res 0,d              ; Q = up
not_q:
               ld  a,&fd
               in  a,(keyboard)
               bit 3,a
               jr  nz,not_f
               res 3,e              ; F = down 2 (toggle FX)
not_f:         rra
               jr  c,not_a
               res 3,d              ; A = down
not_a:
               ld  a,&df
               in  a,(keyboard)
               rra
               jr  c,not_p
               res 2,d              ; P = right
not_p:         rra
               jr  c,not_o
               res 1,d              ; O = left
not_o:
               ld  a,&7f
               in  a,(keyboard)
               rra
               jr  c,not_space
               res 2,e              ; space = right 2 (jump)
not_space:     rra
               jr  c,not_sym
               res 2,e              ; sym = right 2 (jump)
not_sym:       rra
               jr  c,not_m
               res 0,e              ; M = up 2 (toggle music)
not_m:

; Kempston joystick
read_joy:      in  a,(kempston)     ; read Kempston joystick
               inc a
               cp  2
               jr  c,not_fire       ; ignore blank or invalid inputs
               dec a
               rra
               jr  nc,not_right
               res 2,d              ; right
not_right:     rra
               jr  nc,not_left
               res 1,d              ; left
not_left:      rra
               jr  nc,not_down
               res 3,d              ; down
not_down:      rra
               jr  nc,not_up
               res 0,d              ; up
not_up:        rra
               jr  nc,not_fire
               res 2,e              ; fire = right 2 (jump)
not_fire:

               ld  a,d              ; dip including controls
               cpl                  ; invert so set=pressed
               and %00001111        ; keep only direction bits
               jr  z,joy_done       ; skip if nothing pressed
               ld  c,a
               neg
               and c                ; keep least significant set bit
               cp  c                ; was it the only bit?
               jr  z,joy_done       ; skip if so

               ld  a,(last_controls); last valid (single) controls
               xor c                ; check for differences
               or  %11110000        ; convert to mask
               ld  c,a
               ld  a,d              ; current controls
               or  %00001111        ; release all directions
               and c                ; press the changed key
               jr  joy_multi        ; apply change but don't save

joy_done:      ld  a,d
               ld  (last_controls),a; update last valid controls
input_done:    ld  a,d              ; use original value
joy_multi:     ld  (&5000),a
               ld  a,e
               ld  (&5040),a
               ret

last_controls: defb 0


; Check sprite visibility, returns carry if any visible, no-carry if all hidden
is_visible:    ld  a,&10            ; minimum x/y position to be visible
               ld  b,7              ; 7 sprites to check
               ld  hl,&5062
vis_lp:        cp  (hl)
               ret c
               inc l
               cp  (hl)
               ret c
               inc l
               inc l
               inc l
               djnz vis_lp
               ret

last_tile:     defb 0

; Draw the background tile changes, in 1-5 steps over the 2 double-buffered screens
; We can't see attribute changes, as used for the title logo and level backgrounds.
; To ensure they're updated we force a redraw when changing between menu and game.
do_tiles:      ld  hl,last_tile
               ld  a,(pac_chars+(27*32)+20) ; 'A' in Air on game screen
               cp  (hl)             ; has it changed?
               jr  z,no_refresh     ; don't refresh full display
               ld  (hl),a           ; update new value

               ld  hl,bak_chars1    ; copy of display tiles
               ld  bc,&0800         ; clear both screen copies
               ld  a,&a0            ; space
refresh_lp:    cp  (hl)             ; tile is currently a space?
               jr  nz,non_space
               ld  (hl),c           ; write zero to force redraw
non_space:     inc l
               jr  nz,refresh_lp
               inc h
               djnz refresh_lp
no_refresh:
               call is_visible      ; set carry state for below

tile_state:    ld  a,ixh
               bit 7,a              ; alt screen? (don't disturb carry!)

               jr  c,tile_strips    ; if any sprites are visible we'll draw in strips
               jr  nz,fulldraw_alt     ; full screen draw (alt)

fulldraw_norm: ld  b,28
               ld  de,pac_chars
               ld  hl,bak_chars1-pac_footer
               add hl,de
               jp  tile_comp

fulldraw_alt:  ld  b,28
               ld  de,pac_chars
               ld  hl,bak_chars2-pac_footer
               add hl,de
               jp  tile_comp

tile_strips:   jp  nz,strip_odd
strip_even:    jp  strip_0

strip_0:       ld  b,7
               ld  de,pac_chars+(32*7*0)
               ld  hl,bak_chars1-pac_footer
               add hl,de
               call tile_comp
               ld  hl,strip_1
               ld  (strip_even+1),hl
               ret

strip_1:       ld  b,7
               ld  de,pac_chars+(32*7*1)
               ld  hl,bak_chars1-pac_footer
               add hl,de
               call tile_comp
               ld  hl,strip_2
               ld  (strip_even+1),hl
               ret

strip_2:       ld  b,7
               ld  de,pac_chars+(32*7*2)
               ld  hl,bak_chars1-pac_footer
               add hl,de
               call tile_comp
               ld  hl,strip_3
               ld  (strip_even+1),hl
               ret

strip_3:       ld  b,7
               ld  de,pac_chars+(32*7*3)
               ld  hl,bak_chars1-pac_footer
               add hl,de
               call tile_comp
               ld  hl,strip_0
               ld  (strip_even+1),hl
               ret

strip_odd:     jp  strip_0_alt

strip_0_alt:   ld  b,7
               ld  de,pac_chars+(32*7*0)
               ld  hl,bak_chars2-pac_footer
               add hl,de
               call tile_comp
               ld  hl,strip_1_alt
               ld  (strip_odd+1),hl
               ret

strip_1_alt:   ld  b,7
               ld  de,pac_chars+(32*7*1)
               ld  hl,bak_chars2-pac_footer
               add hl,de
               call tile_comp
               ld  hl,strip_2_alt
               ld  (strip_odd+1),hl
               ret

strip_2_alt:   ld  b,7
               ld  de,pac_chars+(32*7*2)
               ld  hl,bak_chars2-pac_footer
               add hl,de
               call tile_comp
               ld  hl,strip_3_alt
               ld  (strip_odd+1),hl
               ret

strip_3_alt:   ld  b,7
               ld  de,pac_chars+(32*7*3)
               ld  hl,bak_chars2-pac_footer
               add hl,de
               call tile_comp
               ld  hl,strip_0_alt
               ld  (strip_odd+1),hl
               ret


tile_comp:     call find_change     ; scan block for display changes
               dec sp               ; restore the same return address to here
               dec sp

               ld  (hl),a           ; update with new tile value

               ex  de,hl
               set 2,h              ; switch to attributes
               ld  c,(hl)           ; fetch tile attribute
               cp  9
               res 2,h              ; switch back to data
               ex  de,hl

               cp  160
               jr  nz,not_blank

               ld  a,c
               cp  9
               jr  nz,tile_empty
               ld  a,27             ; white block
               jr  tile_mapped
not_blank:
               exx
               ld  l,a
               ld  h,tile_map/256
               ld  a,(hl)
               exx
               and a
               jr  nz,tile_known
tile_empty:    ld  a,64             ; space
tile_known:    cp  65               ; 'A'?
               jr  c,tile_mapped    ; jump if below
               cp  65+26            ; 'Z'+1?
               jr  nc,tile_mapped   ; jump if not letter
               ex  af,af'           ; keep tile safe
               ld  a,c              ; current attribute
               cp  9                ; inverse-style attribute?
               jr  nz,tile_mappedex
               ex  af,af'           ; restore letter tile
               add a,32             ; switch to inverse character set

tile_mapped:   ex  af,af'           ; save tile for later
tile_mappedex: push de
               exx                  ; save to resume find
               pop hl               ; Pac-Man screen address of changed tile

               ld  a,l
               and %00011111        ; column is in bits 0-4
               ld  b,a              ; tile y

               add a,a              ; *2
               add a,a              ; *4
               add a,b              ; *5 (code size to check each byte)
               add a,3              ; skip ld+cp+ret, so we advance pointers
               ld  e,a
               ld  d,find_change/256
               push de              ; return address to resume find

               add hl,hl            ; *2
               add hl,hl            ; *4
               add hl,hl            ; *8 (ignore overflow), H is now mirrored column number
               ld  a,28+2           ; 28 columns wide, offset 2 by additional rows
               sub h                ; unmirror the column
               ld  c,a              ; tile x

draw_tile:     ld  ixl,5            ; offset to centre maze on Speccy display
draw_tile_x:   ld  a,b
               add a,a              ; *2
               ld  b,a
               add a,a              ; *4
               add a,b              ; *6
               ld  l,a
               ld  h,scradtab/256
               ld  e,(hl)
               inc h
               ld  a,(hl)
               or  ixh
               ld  d,a              ; DE holds base addr for screen line

               ld  b,conv_8_6/256
               ld  a,(bc)           ; 4 tiles to 3 byte conversion for tile x
               add a,e              ; add screen LSB
               add a,ixl            ; centre maze on Speccy display
               ld  e,a              ; DE holds addr for tile

               ld  a,c
               ex  af,af'           ; save tile x, restore tile number

               ld  l,a
               ld  h,0
               add hl,hl            ; *2
               ld  b,h
               ld  c,l
               add hl,hl            ; *4
               add hl,bc            ; *6

               ld  a,%00000100      ; +3 normal paging, R3/5/2/7
               ld  bc,&1ffd
               out (c),a

               ex  af,af'
               rra
               jr  c,tile_62
               rra
               jr  c,tile_4

; 11111100
tile_0:        ld  bc,tile_data_0
               add hl,bc
               ld  bc,&0503         ; 5 lines, mask of 00000011
tile_0_lp:     ld  a,(de)
               and c
               or  (hl)
               ld  (de),a
               inc hl
               inc d
               ld  a,d
               and %00000111
               call z,blockdown_de
               djnz tile_0_lp
               ld  a,(de)
               and c
               or  (hl)
               ld  (de),a
               jr  tile_exit

; 00001111 11000000
tile_4:        ld  bc,tile_data_4
               add hl,hl
               add hl,bc
               ld  bc,&05f0         ; 5 lines, mask of 11110000
tile_4_lp:     ld  a,(de)
               and c
               or  (hl)
               ld  (de),a
               inc e
               inc hl
               ld  a,(de)
               and %00111111
               or  (hl)
               ld  (de),a
               dec e
               inc hl
               inc d
               ld  a,d
               and %00000111
               call z,blockdown_de
               djnz tile_4_lp
               ld  a,(de)
               and c
               or  (hl)
               ld  (de),a
               inc e
               inc hl
               ld  a,(de)
               and %00111111
               or  (hl)
               ld  (de),a
               jr  tile_exit

tile_62:       rra
               jr  c,tile_2

; 00000011 11110000
tile_6:        ld  bc,tile_data_6
               add hl,hl
               add hl,bc
               ld  bc,&05fc         ; 5 lines, mask of 11111100
tile_6_lp:     ld  a,(de)
               and c
               or  (hl)
               ld  (de),a
               inc e
               inc hl
               ld  a,(de)
               and %00001111
               or  (hl)
               ld  (de),a
               dec e
               inc hl
               inc d
               ld  a,d
               and %00000111
               call z,blockdown_de
               djnz tile_6_lp
               ld  a,(de)
               and c
               or  (hl)
               ld  (de),a
               inc e
               inc hl
               ld  a,(de)
               and %00001111
               or  (hl)
               ld  (de),a
               jr  tile_exit

; 00111111
tile_2:        ld  bc,tile_data_2
               add hl,bc
               ld  bc,&05c0         ; 5 lines, mask of 11000000
tile_2_lp:     ld  a,(de)
               and c
               or  (hl)
               ld  (de),a
               inc hl
               inc d
               ld  a,d
               and %00000111
               call z,blockdown_de
               djnz tile_2_lp
               ld  a,(de)
               and c
               or  (hl)
               ld  (de),a
               jr  tile_exit

tile_exit:     
               ld  a,%00000001      ; +3 special paging, banks 0/1/2/3
               ld  bc,&1ffd
               out (c),a            ; page ROM

               exx
               ret


; Draw a 12x12 sprite  (H=x, L=y, D=attr)
;
draw_spr:      ld  a,h
               cp  &11
               ret c                ; off bottom of screen
               ld  a,l
               inc a                ; catch 255 as invalid
               cp  &11
               ret c                ; off right of screen

               ld  a,d
               and a                ; sprite palette all black?
               ret z

               call page_screen
               call xy_to_addr
               ld  a,c
               and %00000111        ; shift position

               ex  af,af'
               call map_sprite      ; map sprites to the correct orientation/colour
draw_spr2:
               ex  de,hl
               add a,a              ; *2
               ld  l,a
               ld  h,0
               ld  a,c              ; save sprite attribute
               add hl,hl            ; *4
               ld  b,h
               ld  c,l
               add hl,hl            ; *8
               add hl,bc            ; *12

               ex  af,af'
               rra
               jr  c,rot_odd
rot_even:      rra
               jr  c,rot_2_6
rot_0_4:       rra
               ld  bc,spr_data_4    ; rot_4
               jr  c,spr_2
               ld  bc,spr_data_0    ; rot_0
               jp  spr_2

rot_2_6:       rra
               ld  bc,spr_data_6    ; rot_6
               jr  c,spr_3
               ld  bc,spr_data_2    ; rot_2
               jp  spr_2

rot_odd:       rra
               jr  c,rot_3_7
rot_1_5:       rra
               ld  bc,spr_data_5    ; rot_5
               jr  c,spr_3
               ld  bc,spr_data_1    ; rot_1
               jp  spr_2

rot_3_7:       rra
               ld  bc,spr_data_7    ; rot_7
               jr  c,spr_3
               ld  bc,spr_data_3    ; rot_3
               jp  spr_2

; draw a sprite using 2-byte source data (shifts 0-4)
spr_2:         add hl,hl
               add hl,bc
               ld  b,12
               push de
               jr  spr_2_start
spr_2_lp:      inc d
               ld  a,d
               and %00000111
               call z,blockdown_de
spr_2_start:   ld  a,(de)
               or  (hl)
               ld  (de),a
               inc e
               inc hl
               ld  a,(de)
               or  (hl)
               ld  (de),a
               dec e
               inc hl
               djnz spr_2_lp
               pop hl
               jp  page_rom

; draw a sprite using 3-byte source data (shifts 5-7)
spr_3:         push bc
               ld  b,h
               ld  c,l
               add hl,hl           ; *24
               add hl,bc           ; *36
               pop bc
               add hl,bc
               ld  b,12
               push de
               jr  spr_3_start
spr_3_lp:      inc d
               ld  a,d
               and %00000111
               call z,blockdown_de
spr_3_start:   ld  a,(de)
               or  (hl)
               ld  (de),a
               inc e
               inc hl
               ld  a,(de)
               or  (hl)
               ld  (de),a
               inc e
               inc hl
               ld  a,(de)
               or  (hl)
               ld  (de),a
               dec e
               dec e
               inc hl
               djnz spr_3_lp
               pop hl
               jp  page_rom


; Map an arcade tile number to our tile number, allowing for attribute differences
; and any tiles we've mapped to different locations (we have no fruit tiles)
map_sprite:    ld  b,0
               ld  a,e
               srl a
               rl  b                ; b0=flip-y
               rra
               rl  b                ; b1=flip-y, b0=flip-x

               bit 0,b              ; x-mirrored?
               ret z                ; return if not
               add a,48             ; switch to mirrored sprites

               cp  96               ; off the end?
               ret c                ; return if in range
               sub 48-4             ; kangaroo and pac-man mirrors are adjacent
               ret


; Save the background screen behind locations we're about to draw active sprites
;
do_save:       ld  hl,(&5062)       ; pre-fetch position data as we page it out
               push hl
               ld  hl,(&5064)
               push hl
               ld  hl,(&5066)
               push hl
               ld  hl,(&5068)
               push hl
               ld  hl,(&506a)
               push hl
               ld  hl,(&506c) 

               call page_screen

               ld  de,spr_save_7
               call spr_save

               pop hl
               ld  de,spr_save_6
               call spr_save

               pop hl
               ld  de,spr_save_5
               call spr_save

               pop hl
               ld  de,spr_save_4
               call spr_save

               pop hl
               ld  de,spr_save_3
               call spr_save

               pop hl
               ld  de,spr_save_2
               call spr_save

               call page_rom
               ret

; Save a single sprite-sized block, if visible
spr_save:      ld  a,h
               cp  &10
               ret c                ; off bottom of screen
               ld  a,l
               inc a                ; catch 255 as invalid
               cp  &11
               ret c                ; off right of screen

               ld  a,d
               or  ixh
               ld  d,a

               call xy_to_addr      ; convert to Speccy display address

               ex  de,hl
               ld  (hl),e           ; data low
               inc l
               ld  (hl),d           ; data high
               inc l
               ex  de,hl            ; HL=screen, DE=save

               ld  bc,3*12          ; 3 bytes and 12 lines

save_lp:       ld  a,l
               ldi
               ldi
               ldi
               ret po               ; return if done
               ld  l,a
               inc h
               ld  a,h
               and %00000111
               jp  nz,save_lp
               call blockdown_hl
               jp  save_lp

;
; Remove the previous sprites by restoring the image that was underneath them
;
do_restore:    call page_screen

               ld  hl,spr_save_2
               call spr_restore
               ld  hl,spr_save_3
               call spr_restore
               ld  hl,spr_save_4
               call spr_restore
               ld  hl,spr_save_5
               call spr_restore
               ld  hl,spr_save_6
               call spr_restore
               ld  hl,spr_save_7
               call spr_restore

               jp  page_rom


; Restore a single sprite-sized block, if data was saved
spr_restore:   ld  a,h
               or  ixh
               ld  h,a
               ld  a,(hl)
               and a
               ret z                ; no data saved

               ld  (hl),0           ; flag 'no restore data'

               ld  e,a              ; data low
               inc l
               ld  d,(hl)           ; data high
               inc l

               ld  bc,3*12          ; 3 bytes of 12 lines

restore_lp:    ld  a,e
               ldi
               ldi
               ldi
               ret po
               ld  e,a
               inc d
               ld  a,d
               and %00000111
               jp  nz,restore_lp
               call blockdown_de
               jp  restore_lp


; Draw the currently visible sprites, in the correct order for overlaps
; Note: sprite order changes depending on mode, so not always as listed!
;
do_sprites:
               ld  hl,(&506c)
               ld  de,(&4ffc)
               call draw_spr        ; fruit

               ld  hl,(&506a)
               ld  de,(&4ffa)
               call draw_spr        ; pacman

               ld  hl,(&5068)
               ld  de,(&4ff8)
               call draw_spr        ; orange ghost

               ld  hl,(&5066)
               ld  de,(&4ff6)
               call draw_spr        ; cyan ghost

               ld  hl,(&5064)
               ld  de,(&4ff4)
               call draw_spr        ; pink ghost

               ld  hl,(&5062)
               ld  de,(&4ff2)
               call draw_spr        ; red ghost

               ret


; Build the sound table and initialise the AY-3-8912 chip
;
sound_init:    ld  bc,sound_table

sound_lp:      ld  a,b              ; map entry address to freq
               and &3f
               rra
               ld  d,a
               ld  a,c
               rra
               ld  e,a              ; freq (divisor) now in DE

               ld  hl,0
               exx
               ld  de,&da7a         ; dividend in DEHL
               ld  hl,&8000         ; 111861 << 15 = 0xda7a8000 
               ld  b,16
               and a
div_lp:        adc hl,hl            ; shift up for next division
               rl  e
               rl  d
               exx
               adc hl,hl            ; include new bit
               sbc hl,de            ; does it divide?
               jr  nc,div_ok
               add hl,de            ; add back if not, setting carry
div_ok:        exx
               ccf                  ; set carry if it divided
               djnz div_lp
               adc hl,hl            ; include final bit

               ld  a,h
               ex  af,af'
               ld  a,l
               exx
               ld  (bc),a           ; note LSB
               inc c
               ex  af,af'
               ld  (bc),a           ; note MSB
               inc bc               ; freq++
               ex  af,af'

               xor c
               and %00000111
               out (border),a       ; flash the border to show we're busy

               bit 5,b
               jr  z,sound_lp

               xor a
               out (border),a

               ld  hl,sinit_data
               ld  de,&ffbf
               ld  c,&fd
sinit_lp:      ld  a,(hl)
               and a
               ret m
               ld  b,d
               out (c),a
               inc hl
               ld  a,(hl)
               inc hl
               ld  b,e
               out (c),a
               jr sinit_lp

; Sound init: set volumes to zero, enable tones A+B+C, end
sinit_data: defb &08,0, &09,0, &0a,0, &07,%00111000, &ff


; Map the current sound chip frequencies to the AY
;
do_sound:      ld  hl,&5051         ; voice 0 freq and volume
               ld  a,(&5045)        ; voice 0 waveform
               call map_sound
               xor a
               call play_sound

               ld  hl,&5051+5       ; voice 1 freq and volume
               ld  a,(&504a)        ; voice 1 waveform
               call map_sound
               ld  a,1
               call play_sound

               ld  hl,&5051+5+5     ; voice 2 freq and volume
               ld  a,(&504f)        ; voice 2 waveform
               call map_sound
               ld  a,2
               call play_sound

               ret

map_sound:     ld  b,a              ; save waveform

               ld  a,(hl)
               and %00001111
               add a,a
               add a,a
               add a,a
               add a,a
               ld  e,a
               inc hl
               ld  a,(hl)
               and %00001111
               ld  d,a
               inc hl
               ld  a,(hl)
               add a,a
               add a,a
               add a,a
               add a,a
               or  d
               ld  d,a
               or  e                ; check for zero frequency
               inc hl
               inc hl
               ld  a,(hl)           ; volume
               ex  de,hl

               jr  nz,not_silent
               xor a                ; zero frequency gives silence
not_silent:    ex  af,af'           ; save volume for caller

               ld  a,b
               cp  5                ; waveform used when eating ghost?
               jr  z,eat_sound      ; if so, don't divide freq by 8
               srl h
               rr  l
               srl h
               rr  l
               srl h
               rr  l
eat_sound:
               ld  a,h
               or  &c0              ; MSB of sound table
               ld  h,a
               res 0,l

               ld  a,(hl)           ; pick up LSB
               inc hl
               ld  h,(hl)           ; pick up MSB
               ld  l,a

               ret

; Update a single voice, setting the note number and volume
play_sound:    ld  de,&ffbf         ; sound register port MSB
               ld  c,&fd            ; LSB

               add a,a              ; 2 registers per tone
               ld  b,d
               out (c),a            ; tone low
               ld  b,e
               out (c),l

               inc a
               ld  b,d
               out (c),a            ; tone high
               ld  b,e
               out (c),h

               rra
               or  %00001000
               ld  b,d
               out (c),a            ; volume
               ex  af,af'
               ld  b,e
               out (c),a            ; volume data

               ret


; Create the look-up tables used to speed up various calculations
;
make_tables:   ld  hl,conv_8_6
               xor a
conv_86_lp:    ld  (hl),a           ; 0
               inc l
               ld  (hl),a           ; 0
               inc a
               inc l
               ld  (hl),a           ; 1
               inc a
               inc l
               ld  (hl),a           ; 2, etc. (repeating pattern)
               inc a
               inc l
               jr  nz,conv_86_lp

               ; note: HL re-used from above
               ld  de,conv_y
               ld  bc,conv_x
mirror_lp:     xor a
               sub c                ; mirror y-axis
               ld  l,a
               ld  a,(hl)           ; map to Speccy coords
               ld  (de),a
               xor a
               sub e                ; mirror x-axis
               ld  l,a
               ld  a,(hl)           ; map to Speccy coords
               add a,34             ; centre on display
               ld  (bc),a
               inc e
               inc c
               jr  nz,mirror_lp


               ld  hl,tile_data_4
               ld  de,tile_data_6
               exx
               ld  hl,tile_data_0
               ld  de,tile_data_2
               ld  c,192            ; 192 tiles
tilerot_lp:    ld  b,6              ; 6 lines per tile
tilerot_lp2:   ld  a,(hl)
               inc hl
               srl a
               rra
               ld  (de),a           ; >> 6
               inc de
               exx
               ld  c,0
               rra
               rr  c
               rra
               rr  c
               ld  (hl),a           ; >> 4
               inc l
               ld  (hl),c
               inc hl
               ex  de,hl
               rra
               rr  c
               rra
               rr  c
               ld  (hl),a           ; >> 2
               inc l
               ld  (hl),c
               inc hl
               ex  de,hl
               exx
               djnz tilerot_lp2
               dec c
               jr  nz,tilerot_lp


               ld  hl,spr_data_5
               ld  de,76*3*12
               exx
               ld  hl,spr_data_0
               ld  de,76*2*12

               ld  c,76             ; 76 sprites
spr_rot_lp:    push bc
               ld  b,12             ; 12 lines per sprite
spr_rot_lp2:   push bc

               ld  c,(hl)           ; take a line from spr_data_0
               inc hl
               ld  a,(hl)
               dec hl

               push hl              ; save
               ld  b,4              ; four more 2-byte shifted versions
spr_rot_lp3:   add hl,de            ; next shifted copy
               srl c                ; >> 1
               rra
               ld  (hl),c           ; spr_data_1 to spr_data_4
               inc hl
               ld  (hl),a
               dec hl
               djnz spr_rot_lp3

               pop hl               ; restore spr_data_0 position
               inc hl               ; advance to next line
               inc hl

               ex  af,af'           ; preserve A and carry from final rra above
               ld  a,c              ; copy for exx
               exx
               ld  c,a              ; restore C
               ex  af,af'           ; restore A and carry
               ld  b,0              ; extra shift register
               rr  b                ; recover carry
               ex  af,af'

               ld  a,3              ; three 3-byte shifted versions
               push hl              ; save
spr_rot_lp4:   ex  af,af'

               srl c                ; >> 5 to 7
               rra
               rr  b

               ld  (hl),c           ; spr_data_5 to spr_data_7
               inc hl
               ld  (hl),a
               inc hl
               ld  (hl),b
               dec hl
               dec hl
               add hl,de            ; next shifted copy

               ex  af,af'
               dec a
               jr  nz,spr_rot_lp4

               pop hl               ; restore spr_data_5 position
               inc hl               ; advance to next line
               inc hl
               inc hl
               exx                  ; back to spr_data_0

               pop bc
               djnz spr_rot_lp2     ; complete lines

               pop bc
               dec c
               jr  nz,spr_rot_lp    ; complete sprites


               ld hl,scradtab
               ld de,&4000          ; Speccy screen base
               ld b,&c0             ; 192 lines
scrtab_lp:     ld (hl),e
               inc h
               ld (hl),d
               dec h
               inc l
               inc d
               ld  a,d
               and %00000111
               call z,blockdown_de
               djnz scrtab_lp

               ret

; Map a Pac-Man screen coordinate to a Speccy display address, scaling down from 8x8 to 6x6 as we go
;
xy_to_addr:    ld  b,conv_y/256
               ld  c,h
               ld  a,(bc)           ; look up y coord
               ld  h,conv_x/256
               ld  c,(hl)           ; look up x coord

               ld  h,scradtab/256
               ld  l,a
               ld  b,(hl)
               inc h
               ld  a,(hl)
               or  ixh
               ld  h,a
               ld  l,b
               ld  a,c
               and %11111000
               rra
               rra
               rra
               add a,l
               ld  l,a
               ret

blockdown_hl:  ld a,l
               add a,32
               ld l,a
               ret c

               ld a,h
               sub 8
               ld h,a
               ret

blockdown_de:  ld a,e
               add a,32
               ld e,a
               ret c

               ld a,d
               sub 8
               ld d,a
               ret


; Check that Spectranet traps are disabled, if one is connected
chk_specnet:   ld  hl,&3ff9         ; PAGEIN
               ld  a,(hl)           ; save currently paged value at trap
               push af
               push hl

               ld  hl,&4000         ; first byte in (display) RAM after trap
               ld  c,(hl)           ; save current value
               ld  (hl),&c9         ; RET
               call &3ff9           ; attempt page-in
               ld  (hl),c           ; restore display byte

               pop hl
               pop af
               cp  (hl)             ; did the paging change?
               ret z                ; return Z if not (no Spectranet or traps disabled)
               jp  &007c            ; exit via RET in Speccy ROM to page out


; Clear both screens and sprite save areas, and set default attrs
init_screens:  call page_screen

               ld  b,2              ; 2 screens to prepare
scrinit_lp:    push bc

               ld  hl,&4000         ; Speccy display
               ld  de,&4001
               ld  bc,&1800         ; display length

               ld  a,h
               or  ixh              ; adjust for current screen
               ld  h,a
               ld  d,a

               ld  (hl),l           ; clear display data
               ldir

               ld  bc,&0300         ; &300 bytes to fill
               ld  a,screen_attr
               ld  (hl),a           ; fill display attrs
               ldir

               ld  bc,spr_save_end-spr_save_2
               ld  (hl),l           ; clear sprite restore data
               ldir

               call do_flip         ; switch to other display
               pop bc
               djnz scrinit_lp      ; finish both screens

               jp  page_rom


; Display a message using the ROM routines
; String in HL (null-terminated), paging expected to be correct
;
print_msg:     push hl
               call &0d6b           ; CLS
               ld  a,2              ; main screen
               call &1601           ; CHAN-OPEN
               pop hl

msg_lp:        ld  a,(hl)
               and a
               ret z
               rst 16               ; PRINT-A
               inc l
               jr  msg_lp


loading_msg:   defm "pacminer v0.1"
               defb 0

specnet_msg:   defm "Disable Spectranet traps now..."
               defb 0

plus2a3_msg:   defm "This program requires a +2A/+3"
               defb 0


               defs (-$)%256          ; align to next 256-byte boundary

; Scan a 32-byte block for changes, used for fast scanning of the Pac-Man display
; Aligned on a 256-byte boundary for easy resuming of the scanning
;
find_change:   ld  a,(de)   ; 0
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 1
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 2
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 3
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 4
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 5
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 6
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 7
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 8
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 9
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 10
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 11
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 12
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 13
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 14
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 15
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 16
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 17
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 18
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 19
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 20
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 21
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 22
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 23
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 24
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 25
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 26
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 27
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 28
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 29
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 30
               cp  (hl)
               ret nz
               inc e
               inc l

               ld  a,(de)   ; 31
               cp  (hl)
               ret nz
               inc de       ; 16-bit increment as we may be at 256-byte boundary
               inc hl

               dec b
               jp  nz,find_change   ; jump too big for DJNZ

               pop hl               ; junk return to update
               ret


               defs (-$)%256          ; align to next 256-byte boundary

               ; Map native tiles to our limited tile set (tiles.png)
tile_map:      defb 0,2,3,28,47,48,49,50, 19,19,52,136,136,51,136,136, 136,136,136,136,46,45,44,43, 41,41,41,42,41,42,22,39
               defb 18,0,18,18,18,18,18,0, 0,0,0,0,0,0,0,0, 33,33,33,33,33,33,36,33, 34,34,35,37,35,35,38,40
               defb 30,31,62,63,32,32,20,21, 168,169,170,171,172,173,174,175, 168,169,170,171,172,173,174,175, 168,169,170,171,172,173,174,175
               defb 10,11,12,13,14,15,16,17, 136,137,138,139,140,141,142,143, 128,129,130,131,132,133,134,135, 128,129,130,131,132,133,134,135
               defb 136,137,138,139,140,141,142,143, 136,137,138,139,140,141,142,143, 160,161,162,163,164,165,166,167, 136,137,138,139,140,141,142,143
               defb 64,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 79,1,2,3,4,5,6,7, 8,9,0,0,0,0,0,0
               defb 0,65,66,67,68,69,70,71, 72,73,74,75,76,77,78,79, 80,81,82,83,84,85,86,87, 88,89,90,29,0,0,30,31
               defb 0,65,66,67,68,69,70,71, 72,73,74,75,76,77,78,79, 80,81,82,83,84,85,86,87, 88,89,90,61,0,0,62,63

end_a000:      equ $

new_stack:     equ &b000            ; hangs back into &Axxx

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

               org &b000
; Tables are generated here at run time
conv_8_6:      defs &100
conv_x:        defs &100
conv_y:        defs &100
scradtab:      defs &200
bak_chars1:    defs &400            ; copy of Pac-Man display for normal screen
bak_chars2:    defs &400            ; copy of Pac-Man display for alt screen

end_b000:      equ $

               org &b000
; Graphics are here at load time
load_tiles:    incbin "tiles.bin"      ; 192 tiles * 6 lines * 1 byte per line = 1152 bytes
load_sprites:  incbin "sprites.bin"    ; 76 sprites * 12 lines * 2 byte per line = 1824 bytes

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

               org &c000
; 16K of Pac-Man ROMs
               incbin "pacmmm.6e"
               incbin "pacmmm.6f"
               incbin "pacmmm.6h"
               incbin "pacmmm.6j"

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

end start ; auto-run address
