align 8
gdt:
    dq 0
    dq 0x00209A0000000000                   ; 64-bit code, l=1
    dq 0x0000920000000000                   ; data
gdt_end:
gdtr:
    dw gdt_end - gdt - 1
    dd gdt
