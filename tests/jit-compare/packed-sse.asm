BITS 32
    ; each operation writes to its own destination, so none can mask another
    pandn xmm2, xmm1
    pand  xmm3, xmm1
    por   xmm4, xmm1
    pxor  xmm5, xmm1
    paddb xmm6, xmm1
    psubw xmm7, xmm1
    hlt
