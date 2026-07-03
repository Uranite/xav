%include "dav1d_x86inc.asm"

SECTION_RODATA 8
ra1: dq -1.99004745483397971206
ra2: dq 0.990072250366209938299
pa1: dq -1.69065929318241026102
pa2: dq 0.732480774215850116704
pb0: dq 1.53512485958697020294
pb1: dq -2.69169618940638066817
pb2: dq 1.19839281085285009887

SECTION .text
INIT_YMM avx2

cglobal loud, 5, 13, 16, src, n, stride, st, out
    vmovupd       ymm0, [stq]
    vmovupd       ymm1, [stq + 0x20]
    vmovupd       ymm2, [stq + 0x40]
    vmovupd       ymm3, [stq + 0x60]
    vmovupd       ymm4, [stq + 0x80]
    vmovupd       ymm5, [stq + 0xa0]
    vmovupd       ymm6, [stq + 0xc0]
    vmovupd       ymm7, [stq + 0xe0]
    vxorpd        ymm8, ymm8, ymm8
    vxorpd        ymm9, ymm9, ymm9
    mov           r12, outq
    lea           r11, [strideq*8]
    lea           r8, [srcq + r11]
    lea           r9, [srcq + r11*2]
    lea           r10, [r9 + r11]
    xor           eax, eax
    cmp           rax, nq
    jae           .done
.loop:
    vcvtps2pd     xmm10, [srcq + rax*8]
    vcvtps2pd     xmm13, [r8 + rax*8]
    vinsertf128   ymm10, ymm10, xmm13, 1
    vcvtps2pd     xmm12, [r9 + rax*8]
    vcvtps2pd     xmm13, [r10 + rax*8]
    vinsertf128   ymm12, ymm12, xmm13, 1
    vbroadcastsd  ymm13, [ra2]
    vfnmadd231pd  ymm10, ymm2, ymm13
    vfnmadd231pd  ymm12, ymm3, ymm13
    vbroadcastsd  ymm13, [ra1]
    vfnmadd231pd  ymm10, ymm0, ymm13
    vfnmadd231pd  ymm12, ymm1, ymm13
    vsubpd        ymm13, ymm10, ymm0
    vsubpd        ymm14, ymm0, ymm2
    vsubpd        ymm11, ymm13, ymm14
    vsubpd        ymm13, ymm12, ymm1
    vsubpd        ymm14, ymm1, ymm3
    vsubpd        ymm15, ymm13, ymm14
    vmovapd       ymm2, ymm0
    vmovapd       ymm0, ymm10
    vmovapd       ymm3, ymm1
    vmovapd       ymm1, ymm12
    vbroadcastsd  ymm13, [pa2]
    vfnmadd231pd  ymm11, ymm6, ymm13
    vfnmadd231pd  ymm15, ymm7, ymm13
    vbroadcastsd  ymm13, [pa1]
    vfnmadd231pd  ymm11, ymm4, ymm13
    vfnmadd231pd  ymm15, ymm5, ymm13
    vbroadcastsd  ymm13, [pb2]
    vmulpd        ymm10, ymm6, ymm13
    vmulpd        ymm12, ymm7, ymm13
    vbroadcastsd  ymm13, [pb1]
    vfmadd231pd   ymm10, ymm4, ymm13
    vfmadd231pd   ymm12, ymm5, ymm13
    vbroadcastsd  ymm13, [pb0]
    vfmadd231pd   ymm10, ymm11, ymm13
    vfmadd231pd   ymm12, ymm15, ymm13
    vfmadd231pd   ymm8, ymm10, ymm10
    vfmadd231pd   ymm9, ymm12, ymm12
    vmovapd       ymm6, ymm4
    vmovapd       ymm4, ymm11
    vmovapd       ymm7, ymm5
    vmovapd       ymm5, ymm15
    inc           rax
    cmp           rax, nq
    jb            .loop
.done:
    vmovupd       [stq], ymm0
    vmovupd       [stq + 0x20], ymm1
    vmovupd       [stq + 0x40], ymm2
    vmovupd       [stq + 0x60], ymm3
    vmovupd       [stq + 0x80], ymm4
    vmovupd       [stq + 0xa0], ymm5
    vmovupd       [stq + 0xc0], ymm6
    vmovupd       [stq + 0xe0], ymm7
    vhaddpd       ymm0, ymm8, ymm9
    vpermpd       ymm0, ymm0, 0xd8
    vmovupd       [r12], ymm0
    RET
