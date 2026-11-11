; Test boot sector: prints the first 8 bytes of LBA 2 to COM1, then
; overwrites LBA 2 with "WRITTEN!" and prints "|DONE".
org 0x7c00
bits 16
start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    sti
    mov [drive], dl

    mov si, dap                 ; read LBA 2 -> 0x8000
    mov ah, 0x42
    mov dl, [drive]
    int 0x13
    jc fail

    mov si, 0x8000
    mov cx, 8
    call print_n

    mov si, msg                 ; 0x8000 <- "WRITTEN!"
    mov di, 0x8000
    mov cx, 8
    rep movsb

    mov si, dap                 ; write LBA 2
    mov ax, 0x4300
    mov dl, [drive]
    int 0x13
    jc fail

    mov si, done
    mov cx, 5
    call print_n
    jmp halt

fail:
    mov si, failmsg
    mov cx, 5
    call print_n
halt:
    cli
    hlt
    jmp halt

print_n:                        ; print CX bytes at DS:SI to COM1
    mov dx, 0x3f8
.next:
    lodsb
    out dx, al
    loop .next
    ret

drive:   db 0
msg:     db "WRITTEN!"
done:    db "|DONE"
failmsg: db "|FAIL"
align 4
dap:     db 0x10, 0
         dw 1
         dw 0x8000, 0
         dq 2

times 510-($-$$) db 0
dw 0xaa55
