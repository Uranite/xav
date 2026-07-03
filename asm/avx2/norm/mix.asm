%include "dav1d_x86inc.asm"

SECTION_RODATA 32
fcix: dd 2,2,0,0,6,6,4,4
iA0: dd 0,1,7,0,0,0,0,0
iA1: dd 0,0,0,0,6,7,0,0
iA2: dd 0,0,0,0,0,0,5,6
iS0: dd 5,6,0,0,0,0,0,0
iS1: dd 0,0,4,5,0,0,0,0
iS2: dd 0,0,0,0,3,4,0,0
iS3: dd 0,0,0,0,0,0,2,3
iFC: dd 2,2,1,1,0,0,7,7
iBC: dd 4,4,3,3,2,2,1,1
c707y: dd 0.707,0.707,0.707,0.707,0.707,0.707,0.707,0.707
c05y: dd 0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5
c707: dd 0.707
c05: dd 0.5

SECTION .text
INIT_YMM avx2

%macro G6 2
    vmovups       ymm0, [srcq + %1]
    vmovups       ymm1, [srcq + %1 + 0x20]
    vmovups       ymm2, [srcq + %1 + 0x40]
    vperm2f128    ymm3, ymm0, ymm2, 0x21
    vperm2f128    ymm4, ymm0, ymm1, 0x30
    vblendpd      ymm4, ymm4, ymm3, 1010b
    vperm2f128    ymm5, ymm1, ymm2, 0x30
    vblendpd      ymm5, ymm3, ymm5, 1010b
    vblendps      ymm6, ymm1, ymm0, 00000100b
    vblendps      ymm6, ymm6, ymm2, 00010000b
    vpermps       ymm6, ymm7, ymm6
    vfmadd231ps   ymm4, ymm8, ymm5
    vfmadd231ps   ymm4, ymm8, ymm6
    vmovups       [dstq + rax*8 + %2], ymm4
%endmacro

cglobal mix6, 3, 5, 9, src, dst, n
    vbroadcastss  ymm8, [c707]
    vmovdqa       ymm7, [fcix]
    xor           eax, eax
    mov           r3, nq
    and           r3, -16
    jz            .tail
.loop:
    G6            0x000, 0x00
    G6            0x060, 0x20
    G6            0x0c0, 0x40
    G6            0x120, 0x60
    add           srcq, 0x180
    add           rax, 16
    cmp           rax, r3
    jb            .loop
.tail:
    cmp           rax, nq
    jae           .done
.tloop:
    vmovss        xmm0, [srcq]
    vfmadd231ss   xmm0, xmm8, [srcq + 0x10]
    vfmadd231ss   xmm0, xmm8, [srcq + 0x8]
    vmovss        [dstq + rax*8], xmm0
    vmovss        xmm1, [srcq + 0x4]
    vfmadd231ss   xmm1, xmm8, [srcq + 0x14]
    vfmadd231ss   xmm1, xmm8, [srcq + 0x8]
    vmovss        [dstq + rax*8 + 0x4], xmm1
    add           srcq, 0x18
    inc           rax
    cmp           rax, nq
    jb            .tloop
.done:
    RET

%macro H8 2
    vmovups       ymm0, [srcq + %1]
    vmovups       ymm1, [srcq + %1 + 0x20]
    vmovups       ymm2, [srcq + %1 + 0x40]
    vmovups       ymm3, [srcq + %1 + 0x60]
    vunpcklpd     ymm4, ymm0, ymm1
    vunpcklpd     ymm5, ymm2, ymm3
    vunpckhpd     ymm6, ymm0, ymm1
    vunpckhpd     ymm7, ymm2, ymm3
    vperm2f128    ymm0, ymm4, ymm5, 0x20
    vperm2f128    ymm1, ymm4, ymm5, 0x31
    vperm2f128    ymm2, ymm6, ymm7, 0x31
    vperm2f128    ymm6, ymm6, ymm7, 0x20
    vmovsldup     ymm6, ymm6
    vmulps        ymm2, ymm2, ymm8
    vfmadd231ps   ymm0, ymm9, ymm1
    vfmadd231ps   ymm0, ymm8, ymm2
    vfmadd231ps   ymm0, ymm8, ymm6
    vmovups       [dstq + rax*8 + %2], ymm0
%endmacro

cglobal mix8, 3, 5, 10, src, dst, n
    vbroadcastss  ymm8, [c707]
    vbroadcastss  ymm9, [c05]
    xor           eax, eax
    mov           r3, nq
    and           r3, -16
    jz            .tail
.loop:
    H8            0x000, 0x00
    H8            0x080, 0x20
    H8            0x100, 0x40
    H8            0x180, 0x60
    add           srcq, 0x200
    add           rax, 16
    cmp           rax, r3
    jb            .loop
.tail:
    cmp           rax, nq
    jae           .done
.tloop:
    vmulss        xmm2, xmm8, [srcq + 0x18]
    vmovss        xmm0, [srcq]
    vfmadd231ss   xmm0, xmm9, [srcq + 0x10]
    vfmadd231ss   xmm0, xmm8, xmm2
    vfmadd231ss   xmm0, xmm8, [srcq + 0x8]
    vmovss        [dstq + rax*8], xmm0
    vmulss        xmm2, xmm8, [srcq + 0x1c]
    vmovss        xmm1, [srcq + 0x4]
    vfmadd231ss   xmm1, xmm9, [srcq + 0x14]
    vfmadd231ss   xmm1, xmm8, xmm2
    vfmadd231ss   xmm1, xmm8, [srcq + 0x8]
    vmovss        [dstq + rax*8 + 0x4], xmm1
    add           srcq, 0x20
    inc           rax
    cmp           rax, nq
    jb            .tloop
.done:
    RET

%macro G7 2
    vmovups       ymm0, [srcq + %1]
    vmovups       ymm1, [srcq + %1 + 0x20]
    vmovups       ymm2, [srcq + %1 + 0x40]
    vmovups       xmm3, [srcq + %1 + 0x60]
    vpermps       ymm5, ymm7, ymm0
    vpermps       ymm6, ymm8, ymm1
    vblendps      ymm5, ymm5, ymm6, 00111000b
    vpermps       ymm6, ymm9, ymm2
    vblendps      ymm4, ymm5, ymm6, 11000000b
    vblendps      ymm5, ymm0, ymm1, 00001000b
    vblendps      ymm5, ymm5, ymm2, 00000100b
    vblendps      ymm5, ymm5, ymm3, 00000010b
    vpermps       ymm5, ymm15, ymm5
    vfmadd231ps   ymm4, ymm5, [c05y]
    vpermps       ymm5, ymm10, ymm0
    vpermps       ymm6, ymm11, ymm1
    vblendps      ymm5, ymm5, ymm6, 00001100b
    vpermps       ymm6, ymm12, ymm2
    vblendps      ymm5, ymm5, ymm6, 00110000b
    vpermps       ymm6, ymm13, ymm3
    vblendps      ymm5, ymm5, ymm6, 11000000b
    vfmadd231ps   ymm4, ymm5, [c707y]
    vblendps      ymm5, ymm2, ymm0, 00000100b
    vblendps      ymm5, ymm5, ymm1, 00000010b
    vpermps       ymm5, ymm14, ymm5
    vfmadd231ps   ymm4, ymm5, [c707y]
    vmovups       [dstq + rax*8 + %2], ymm4
%endmacro

cglobal mix7, 3, 5, 16, src, dst, n
    vmovdqa       ymm7,  [iA0]
    vmovdqa       ymm8,  [iA1]
    vmovdqa       ymm9,  [iA2]
    vmovdqa       ymm10, [iS0]
    vmovdqa       ymm11, [iS1]
    vmovdqa       ymm12, [iS2]
    vmovdqa       ymm13, [iS3]
    vmovdqa       ymm14, [iFC]
    vmovdqa       ymm15, [iBC]
    xor           eax, eax
    mov           r3, nq
    and           r3, -16
    jz            .tail
.loop:
    G7            0x000, 0x00
    G7            0x070, 0x20
    G7            0x0e0, 0x40
    G7            0x150, 0x60
    add           srcq, 0x1c0
    add           rax, 16
    cmp           rax, r3
    jb            .loop
.tail:
    cmp           rax, nq
    jae           .done
    vbroadcastss  xmm14, [c707]
    vbroadcastss  xmm15, [c05]
.tloop:
    vmovss        xmm0, [srcq]
    vfmadd231ss   xmm0, xmm15, [srcq + 0x10]
    vfmadd231ss   xmm0, xmm14, [srcq + 0x14]
    vfmadd231ss   xmm0, xmm14, [srcq + 0x8]
    vmovss        [dstq + rax*8], xmm0
    vmovss        xmm1, [srcq + 0x4]
    vfmadd231ss   xmm1, xmm15, [srcq + 0x10]
    vfmadd231ss   xmm1, xmm14, [srcq + 0x18]
    vfmadd231ss   xmm1, xmm14, [srcq + 0x8]
    vmovss        [dstq + rax*8 + 0x4], xmm1
    add           srcq, 0x1c
    inc           rax
    cmp           rax, nq
    jb            .tloop
.done:
    RET
