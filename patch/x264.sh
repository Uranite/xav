#!/bin/sh
set -e
export PATH="/c/Program Files/LLVM/bin:/c/Program Files/NASM:$PATH"
export RC=rc.exe

        # match lookahead with xav cap
        sed -i 's|^#define X264_LOOKAHEAD_MAX 250$|#define X264_LOOKAHEAD_MAX 300|' common/base.h

        # these land in xav's sink; stderr holds the progress frame
        grep -q xav_x264_log common/base.c || sed -i '/^    fprintf( stderr, "x264 \[%s\]: ", psz_prefix );$/,/^    x264_vfprintf( stderr, psz_fmt, arg );$/c\
    extern void xav_x264_log( const char *msg, int len );\
    char buf[4096];\
    int n = snprintf( buf, sizeof(buf), "x264 [%s]: ", psz_prefix );\
    n += vsnprintf( buf + n, sizeof(buf) - n, psz_fmt, arg );\
    if( n >= (int)sizeof(buf) ) n = (int)sizeof(buf) - 1;\
    xav_x264_log( buf, n );' common/base.c

        # c++ flags break its -fno-lto probes
        x264_cflags="${CFLAGS//-fwhole-program-vtables/}"
        # c++ libs get split units from -fwhole-program-vtables
        export CFLAGS="${x264_cflags//-fvisibility-inlines-hidden/} -fsplit-lto-unit"

        # xav = -march=native & never redistributed ; make it constant
        sed -i '/^        uint32_t cpuflags = x264_cpu_detect();$/c\
        uint32_t cpuflags = X264_CPU_SSE2_IS_FAST\
        #ifdef __MMX__\
                          | X264_CPU_MMX\
        #endif\
        #ifdef __SSE__\
                          | X264_CPU_MMX2 | X264_CPU_SSE\
        #endif\
        #ifdef __SSE2__\
                          | X264_CPU_SSE2\
        #endif\
        #ifdef __LZCNT__\
                          | X264_CPU_LZCNT\
        #endif\
        #ifdef __SSE3__\
                          | X264_CPU_SSE3\
        #endif\
        #ifdef __SSSE3__\
                          | X264_CPU_SSSE3\
        #endif\
        #ifdef __SSE4_1__\
                          | X264_CPU_SSE4\
        #endif\
        #ifdef __SSE4_2__\
                          | X264_CPU_SSE42\
        #endif\
        #ifdef __AVX__\
                          | X264_CPU_AVX\
        #endif\
        #ifdef __XOP__\
                          | X264_CPU_XOP\
        #endif\
        #ifdef __FMA4__\
                          | X264_CPU_FMA4\
        #endif\
        #ifdef __FMA__\
                          | X264_CPU_FMA3\
        #endif\
        #ifdef __BMI__\
                          | X264_CPU_BMI1\
        #endif\
        #ifdef __BMI2__\
                          | X264_CPU_BMI2\
        #endif\
        #ifdef __AVX2__\
                          | X264_CPU_AVX2\
        #endif\
        #if defined(__AVX512F__) \&\& defined(__AVX512CD__) \&\& defined(__AVX512BW__) \&\& defined(__AVX512DQ__) \&\& defined(__AVX512VL__)\
                          | X264_CPU_AVX512\
        #endif\
                          ;' encoder/encoder.c

        # we want the highest simd build target has
        grep -q 'xav: keep avx512' encoder/encoder.c || sed -i '/^#if (ARCH_X86 || ARCH_X86_64) \&\& HIGH_BIT_DEPTH$/,/^#endif$/c\
    /* xav: keep avx512; upstream drops it here for hbd */' encoder/encoder.c

        # process wide cpu-dispatch; build the tables once
        grep -q xav_x264_setup encoder/encoder.c || {
                sed -i '/^\/\/#define DEBUG_MB_TYPE$/i\
typedef struct\
{\
    x264_predict_t            predict_16x16[4+3];\
    x264_predict8x8_t         predict_8x8[9+3];\
    x264_predict_t            predict_4x4[9+3];\
    x264_predict_t            predict_8x8c[4+3];\
    x264_predict_t            predict_8x16c[4+3];\
    x264_predict_8x8_filter_t predict_8x8_filter;\
    x264_pixel_function_t     pixf;\
    x264_mc_functions_t       mc;\
    x264_dct_function_t       dctf;\
    x264_zigzag_function_t    zigzagf_progressive;\
    x264_quant_function_t     quantf[2];\
    x264_deblock_function_t   loopf;\
    x264_bitstream_function_t bsf;\
} xav_x264_fns;\
\
static xav_x264_fns xav_fns;\
\
typedef char xav_x264_run_check[\
    offsetof(x264_t, predict_8x8) == offsetof(x264_t, predict_16x16) + sizeof(xav_fns.predict_16x16)\
 \&\& offsetof(x264_t, predict_4x4) == offsetof(x264_t, predict_8x8) + sizeof(xav_fns.predict_8x8)\
 \&\& offsetof(x264_t, predict_8x16c) == offsetof(x264_t, predict_8x8c) + sizeof(xav_fns.predict_8x8c)\
 \&\& offsetof(x264_t, predict_8x8_filter) == offsetof(x264_t, predict_8x16c) + sizeof(xav_fns.predict_8x16c)\
 \&\& offsetof(x264_t, pixf) == offsetof(x264_t, predict_8x8_filter) + sizeof(xav_fns.predict_8x8_filter)\
 \&\& offsetof(x264_t, mc) == offsetof(x264_t, pixf) + sizeof(xav_fns.pixf)\
 \&\& offsetof(x264_t, dctf) == offsetof(x264_t, mc) + sizeof(xav_fns.mc)\
 \&\& offsetof(x264_t, bsf) == offsetof(x264_t, loopf) + sizeof(xav_fns.loopf)\
 \&\& offsetof(xav_x264_fns, predict_8x8) == offsetof(xav_x264_fns, predict_16x16) + sizeof(xav_fns.predict_16x16)\
 \&\& offsetof(xav_x264_fns, predict_4x4) == offsetof(xav_x264_fns, predict_8x8) + sizeof(xav_fns.predict_8x8)\
 \&\& offsetof(xav_x264_fns, predict_8x16c) == offsetof(xav_x264_fns, predict_8x8c) + sizeof(xav_fns.predict_8x8c)\
 \&\& offsetof(xav_x264_fns, predict_8x8_filter) == offsetof(xav_x264_fns, predict_8x16c) + sizeof(xav_fns.predict_8x16c)\
 \&\& offsetof(xav_x264_fns, pixf) == offsetof(xav_x264_fns, predict_8x8_filter) + sizeof(xav_fns.predict_8x8_filter)\
 \&\& offsetof(xav_x264_fns, mc) == offsetof(xav_x264_fns, pixf) + sizeof(xav_fns.pixf)\
 \&\& offsetof(xav_x264_fns, dctf) == offsetof(xav_x264_fns, mc) + sizeof(xav_fns.mc)\
 \&\& offsetof(xav_x264_fns, bsf) == offsetof(xav_x264_fns, loopf) + sizeof(xav_fns.loopf)\
 ? 1 : -1];\
\
void xav_x264_setup( x264_param_t *param )\
{\
    uint32_t cpu = param->cpu;\
    x264_predict_16x16_init( cpu, xav_fns.predict_16x16 );\
    x264_predict_8x8c_init( cpu, xav_fns.predict_8x8c );\
    x264_predict_8x16c_init( cpu, xav_fns.predict_8x16c );\
    x264_predict_8x8_init( cpu, xav_fns.predict_8x8, \&xav_fns.predict_8x8_filter );\
    x264_predict_4x4_init( cpu, xav_fns.predict_4x4 );\
    x264_pixel_init( cpu, \&xav_fns.pixf );\
    x264_dct_init( cpu, \&xav_fns.dctf );\
    x264_zigzag_function_t zigzag_il;\
    x264_zigzag_init( cpu, \&xav_fns.zigzagf_progressive, \&zigzag_il );\
    x264_mc_init( cpu, \&xav_fns.mc, param->b_cpu_independent );\
    x264_t *q = calloc( 1, sizeof(x264_t) );\
    q->param = *param;\
    q->param.i_cqm_preset = X264_CQM_FLAT;\
    x264_quant_init( q, cpu, \&xav_fns.quantf[0] );\
    q->param.i_cqm_preset = X264_CQM_JVT;\
    x264_quant_init( q, cpu, \&xav_fns.quantf[1] );\
    free( q );\
    x264_deblock_init( cpu, \&xav_fns.loopf, PARAM_INTERLACED );\
    x264_bitstream_init( cpu, \&xav_fns.bsf );\
}\
' encoder/encoder.c

                sed -i '/^    x264_predict_16x16_init( h->param.cpu, h->predict_16x16 );$/,/^    x264_bitstream_init( h->param.cpu, \&h->bsf );$/c\
    /* xav: xav_x264_fns mirrors this field order, so each unbroken run is one\
     * memcpy; predict_chroma, zigzagf and quantf are the breaks */\
    memcpy( h->predict_16x16, xav_fns.predict_16x16,\
            sizeof(h->predict_16x16) + sizeof(h->predict_8x8) + sizeof(h->predict_4x4) );\
    memcpy( h->predict_8x8c, xav_fns.predict_8x8c,\
            sizeof(h->predict_8x8c) + sizeof(h->predict_8x16c) + sizeof(h->predict_8x8_filter)\
            + sizeof(h->pixf) + sizeof(h->mc) + sizeof(h->dctf) );\
    memcpy( \&h->zigzagf_progressive, \&xav_fns.zigzagf_progressive, sizeof(h->zigzagf_progressive) );\
    memcpy( \&h->loopf, \&xav_fns.loopf, sizeof(h->loopf) + sizeof(h->bsf) );\
    h->zigzagf = xav_fns.zigzagf_progressive;\
    h->quantf = xav_fns.quantf[h->param.i_cqm_preset != X264_CQM_FLAT];' encoder/encoder.c
        }
chmod +x ./x264-cc-filter.sh
export CC="$PWD/x264-cc-filter.sh"
./configure \
    --disable-cli --enable-static --disable-opencl --disable-thread \
    --disable-interlaced --disable-avs --disable-swscale --disable-lavf \
    --disable-ffms --disable-gpac --disable-lsmash --disable-bashcompletion \
    --bit-depth=10 --chroma-format=420 \
    --extra-cflags=" -fms-runtime-lib=static -O3 -DNDEBUG -march=native"
make -j"$(nproc)" libx264.a
ls -la libx264.a

# msys ar writes a GNU container lld-link will not read; rebuild in MSVC
# format. Globs keep full paths: several objects share a basename
# (set-10/macroblock-10/cabac-10 live in both common/ and encoder/).
llvm-lib /OUT:libx264-msvc.lib common/*.o common/x86/*.o encoder/*.o
mv -f libx264-msvc.lib libx264.a
ls -la libx264.a
