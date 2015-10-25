; Machine IDs

#define MID_PC_82               0x02
#define MID_PC_83               0x03
#define MID_PC_8X               0x23
#define MID_CALC_8X             0x73
#define MID_CALC_82             0x82
#define MID_CALC_83             0x83
#define MID_TI_KEYBOARD         0xE0
#define MID_KOS_RESERVED_MIN    0x40 ; Reserved for kernel use
#define MID_KOS_RESERVED_MAX    0x50 ; Reserved for kernel use
; To the best of my knowledge, TI does not use 0x40-0x50

la_reset_buffer:
    push af
        xor a
        ld (la_header_ix), a
    pop af
    ret

la_handleInterrupt:
    bit BIT_LA_INT_RX_DONE, a
    jr nz, .rx_done
    bit BIT_LA_INT_TX_DONE, a
    jr nz, .tx_done
    bit BIT_LA_INT_ERROR, a
    jr nz, .la_error
    jp sysInterruptDone
.rx_done:
    in a, (PORT_LINK_ASSIST_RX_BUFFER) ; ack
    call la_rx_handle_byte
    jp sysInterruptDone
.tx_done:
    ld bc, (io_send_remain)
    xor a
    cp b
    jr nz, .tx_part
    cp c
    jr nz, .tx_part
    in a, (PORT_LINK_ASSIST_ENABLE)
    res BIT_LA_ENABLE_INT_TX, a
    out (PORT_LINK_ASSIST_ENABLE), a ; Disable sending
    jp sysInterruptDone
.tx_part:
    ld hl, (io_send_queue)
    ld a, (hl)
    out (PORT_LINK_ASSIST_TX_BUFFER), a
    inc hl
    dec bc
    ld (io_send_queue), hl
    ld (io_send_remain), bc
    ld hl, 0
    call cpHLBC
    jp nz, sysInterruptDone
    ; Buffer empty
    in a, (PORT_LINK_ASSIST_ENABLE)
    res BIT_LA_ENABLE_INT_TX, a
    out (PORT_LINK_ASSIST_ENABLE), a ; Disable sending
    ; Run callback
    ld hl, sysInterruptDone
    push hl
    ld hl, (io_send_callback)
    push hl
    call cpHLBC
    ret nz
    ; If they didn't provide a callback:
    pop hl
    ret
.la_error:
    in a, (PORT_LINK_ASSIST_ENABLE)
    res BIT_LA_ENABLE_INT_TX, a
    out (PORT_LINK_ASSIST_ENABLE), a
    ld hl, 0
    ld (io_send_remain), hl ; abort tx

    call la_reset_buffer ; abort rx

    jp sysInterruptDone

initIO:
    ld bc, default_header_handlers_end - default_header_handlers
    call malloc
    ld a, 0xFE
    call reassignMemory ; make permanent
    push ix \ pop de
    ld hl, default_header_handlers
    ldir
    ld (io_header_handlers), ix
    ret

default_header_handlers:
    ;db machine id, expected header length, thread ID
    ;dw handler
    .db MID_TI_KEYBOARD, 3, 0xFE
    .dw handle_keyboard_header
    .db 0xFF
default_header_handlers_end:

;; ioRegisterHandler [I/O]
;;  Registers an I/O packet handler for a given machine ID.
;; Inputs:
;;  A: Machine ID
;;  B: Expected header length
;;  IX: Callback
;; Notes:
;;  The "expected header length" is the length of the packet header at the time
;;  you want your callback told about it. The maximum is 4.
;;  
;;  During normal operation, your callback will be called with the Z flag set and
;;  HL set to the address of the packet header.
;;  
;;  Your callback will be called during an interrupt, so make it short and sweet.
;;  If you return HL != 0 and BC != 0, we'll assume that HL is a pointer to a
;;  buffer to be filled with BC bytes from the rest of the packet. Your callback
;;  will be run again once we get that many bytes, but this time with Z reset.
;;  
;;  If a handler has already been reserved with this machine ID, it will take
;;  precedence.
ioRegisterHandler:
    push hl
    push de
        push af
            push bc
                push ix
                push ix
                    ld ix, (io_header_handlers)
                    ld b, (ix + -1)
                    ld c, (ix + -2)
                    inc bc \ inc bc \ inc bc
                    inc bc \ inc bc
                    call realloc ; Add 5 bytes to header handlers
                    ; TODO: OOM
                    ld (io_header_handlers), ix
                    call memSeekToEnd
                    push ix \ pop hl
                    ld (hl), 0xFF \ dec hl
                pop de
                pop ix
                ld (hl), d \ dec hl
                ld (hl), e \ dec hl
                call getCurrentThreadID
                ld (hl), a \ dec hl
            pop bc
            ld (hl), b \ dec hl
        pop af
        ld (hl), a
    pop de
    pop hl
    ret

; TODO: remove handlers when the owning thread exits

;; ioSendBuffer [I/O]
;;  Sends a buffer of bytes over I/O.
;; Inputs:
;;  HL: Buffer
;;  BC: Length
;;  IX: Callback (or 0)
;; Outputs:
;;  Z: Set if successful, reset if I/O is busy
;; Notes:
;;  This is an asyncronous operation. Your callback will be invoked
;;  (outside the context of your thread) when the send is complete.
;;  Please keep your callback short and sweet, as it will be called
;;  during an interrupt. You are advised to suspend your main thread
;;  or use [[condWait]] and have your callback resume/notify it.
ioSendBuffer:
    push bc
    push af
    push hl
        ld hl, (io_send_remain)
        xor a
        cp h \ jr nz, .fail
        cp l \ jr nz, .fail
    pop hl \ push hl
        ld (io_send_queue), hl
        ld (io_send_remain), bc
        ld (io_send_callback), ix
        in a, (PORT_LINK_ASSIST_ENABLE)
        set BIT_LA_ENABLE_INT_TX, a
        out (PORT_LINK_ASSIST_ENABLE), a
    pop hl
    pop af
    pop bc
    cp a
    ret
.fail:
    pop hl
    ld b, a
    pop af
    or 1
    ld a, b
    pop bc
    ret

la_check_timeout:
    push af
    push hl
    push de
    push bc
        ld a, (la_header_ix)
        or a
        jr z, .done ; Skip if this is the first byte of a packet

        ld hl, (la_last_byte_time)
        ld bc, 200 ; 2 seconds ish
        add hl, bc
        ex de, hl
        ld hl, (kernel_current_time)
        sbc hl, de
        jr c, .done
        xor a
        ld (la_header_ix), a ; drop packet
.done:
        ld hl, (kernel_current_time)
        ld (la_last_byte_time), hl
    pop bc
    pop de
    pop hl
    pop af
    ret

la_rx_handle_byte:
    call la_check_timeout
    ld b, a
    ld a, (la_header_ix)
    cp 4
    jr z, la_handle_data
    ld hl, la_header_buffer
    add a, l \ ld l, a \ jr nc, $+3 \ inc h
    ld (hl), b
    ld hl, la_header_ix
    inc (hl)
.handle_header_part:
    ld a, (la_header_buffer) ; machine ID
    ld b, a
    ld hl, (io_header_handlers)
.header_handler_find:
    ld a, (hl)
    inc hl
    cp 0xFF
    jp z, la_reset_buffer
    cp b
    jr z, .found
    inc hl \ inc hl \ inc hl \ inc hl
    jr .header_handler_find
.found:
    ld b, (hl)
    ld a, (la_header_ix)
    cp b
    ret nz
    inc hl
    ld a, (hl) ; Thread ID
    ; TODO: set context to that thread (so kcall et all works)
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex hl, de
    call la_reset_buffer
    ld de, la_header_buffer
    push hl
    ex de, hl
    ret
.not_found:
    jp la_reset_buffer
la_handle_data:
    ; TODO
    jp la_reset_buffer