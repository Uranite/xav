#!/bin/sh
set -e
export PATH="/c/Program Files/LLVM/bin:/c/Program Files/NASM:$PATH"
export RC=rc.exe

        # 1 memcpy per param clone; no cpu_detect, default fill, 350 field walk
        grep -q 'memcpy(param, p, sizeof(x265_param))' encoder/api.cpp || sed -i '/^    if(param) PARAM_NS::x265_param_default(param);$/,/^    x265_copy_params(zoneParam, p);$/c\
    if (!param || !latestParam || !zoneParam)\
        goto fail;\
    memcpy(param, p, sizeof(x265_param));\
    memcpy(latestParam, p, sizeof(x265_param));\
    memcpy(zoneParam, p, sizeof(x265_param));' encoder/api.cpp
        sed -i '/x265_log(param, X265_LOG_INFO, "HEVC encoder version/d' encoder/api.cpp
        sed -i '/x265_log(param, X265_LOG_INFO, "build info/d' encoder/api.cpp
        sed -i '/^    x265_print_params(param);$/d' encoder/api.cpp
        sed -i '/^    x265_setup_primitives(param);$/d' encoder/api.cpp

        # asm tables become process wide
        sed -i '/^    x265_report_simd(param);$/d' common/primitives.cpp
        grep -q xav_x265_setup common/primitives.cpp || cat >> common/primitives.cpp <<- 'X265SETUP'

	extern "C" void xav_x265_setup(x265_param *param) { X265_NS::x265_setup_primitives(param); }
	X265SETUP

        # these land in xav's sink; never build a buffer
        grep -q xav_x265_log common/common.cpp || {
                sed -i 's|^void general_log(const x265_param\* param, const char\* caller, int level, const char\* fmt, ...)$|extern "C" void xav_x265_log(const char *msg, int len);\nvoid general_log(const x265_param* param, const char* caller, int level, const char* fmt, ...)|' common/common.cpp
                sed -i 's|^    if (param \&\& level > param->logLevel)$|    if (level > X265_LOG_WARNING)|' common/common.cpp
                sed -i 's|^    vsnprintf(buffer + p, bufferSize - p, fmt, arg);$|    p += vsnprintf(buffer + p, bufferSize - p, fmt, arg);\n    if (p >= bufferSize) p = bufferSize - 1;|' common/common.cpp
                sed -i 's|^    fputs(buffer, stderr);$|    xav_x265_log(buffer, p);|' common/common.cpp
                sed -i 's|^        fputs(buffer, stderr);$|        xav_x265_log(buffer, p);|' common/common.cpp
        }

        # scalar per-pixel luma/chroma histogram per frame; remove
        sed -i 's@^    if (param.csvLogLevel >= 2 || param.maxCLL || param.maxFALL)$@    if (0)@' common/picyuv.cpp
        sed -i 's@^    if (param.csvLogLevel >= 2)$@    if (0)@' common/picyuv.cpp

        # remove per frame free, re-malloc
        grep -q 'xav swap' encoder/nal.cpp || sed -i '/^void NALList::takeContents(NALList& other)$/,/^}$/c\
void NALList::takeContents(NALList\& other)\
{\
    /* xav swap: both lists keep a buffer, neither hits the allocator */\
    uint8_t* buf = m_buffer;\
    uint32_t alloc = m_allocSize;\
\
    m_buffer = other.m_buffer;\
    m_allocSize = other.m_allocSize;\
    m_occupancy = other.m_occupancy;\
\
    m_numNal = other.m_numNal;\
    memcpy(m_nal, other.m_nal, sizeof(x265_nal) * m_numNal);\
\
    other.m_numNal = 0;\
    other.m_occupancy = 0;\
    other.m_buffer = buf;\
    other.m_allocSize = alloc;\
}' encoder/nal.cpp

        sed -i 's|^%if FORMAT_ELF$|%if 0 ; xav: non-PIC build has no GOT; the lea is a plain abs32|' common/x86/pixel-util8.asm

        # frame encoder; runs on the caller; a worker is one thread; encode order is fixed
        grep -q setupInPlace encoder/frameencoder.h || sed -i '/^class FrameEncoder : public WaveFront, public Thread$/,/^public:$/s|^public:$|public:\n\n    /* xav: nothing here is threaded; threadMain is only this encoder'"'"'s setup now */\n    void setupInPlace() { threadMain(); }\n|' encoder/frameencoder.h
        grep -q 'xav: compress in place' encoder/frameencoder.cpp || sed -i 's|^    m_enable.trigger();$|    /* xav: compress in place. the bCTUInfo and AVC_INFO waits that guarded this\n     * in threadMain only ever complete from another thread, and there is none */\n    for (int layer = 0; layer < m_param->numLayers; layer++)\n        compressFrame(layer);|' encoder/frameencoder.cpp
        sed -i '/^    m_done.trigger();     \/\* signal that thread is initialized \*\/$/,/^}$/c\
}' encoder/frameencoder.cpp
        sed -i '/^        \/\* block here until worker thread completes \*\/$/d' encoder/frameencoder.cpp
        sed -i '/^        m_done.wait();$/d' encoder/frameencoder.cpp
        sed -i '/^        m_frameEncoder\[i\]->start();$/,/^        m_frameEncoder\[i\]->m_done.wait(); \/\* wait for thread to initialize \*\/$/c\
        m_frameEncoder[i]->setupInPlace();' encoder/encoder.cpp
        sed -i '/^            m_frameEncoder\[i\]->m_enable.trigger();$/d' encoder/encoder.cpp

        # with no pool, the numaPools strlen+strcmp per encoder goes
        sed -i 's|^    bool allowPools = !strlen(p->numaPools) \|\| strcmp(p->numaPools, "none");$|    bool allowPools = false; /* xav: this build has no worker pool to allocate */|' encoder/encoder.cpp
        sed -i 's|^    if (m_param->lookaheadThreads > 0)$|    if (0) /* xav: the lookahead runs on the caller, like everything else */|' encoder/encoder.cpp

        # match lookahead with xav cap
        sed -i 's|^#define X265_LOOKAHEAD_MAX 250$|#define X265_LOOKAHEAD_MAX 300|' x265.h

        sed -i 's@^    pps->numRefIdxDefault\[0\] = 1 + !!m_param->bEnableSCC;;$@    /* xav: the qp a frame of base complexity gets, which is the anchor the\n     * rate factor is built on in RateControl::init and getQScale */\n    double anchor = m_param->rc.rfConstant;\n    if (m_param->rc.cuTree \&\& !m_param->rc.hevcAq)\n        anchor += (1.0 - m_param->rc.qCompress) * (13.5 + 6.0 * X265_LOG2(BASE_FRAME_DURATION /\n                  CLIP_DURATION((double)m_param->fpsDenom / m_param->fpsNum)));\n    m_iPPSQpMinus26 = x265_clip3(-(26 + QP_BD_OFFSET), 25, (int)(anchor + 0.5) - 26);\n\n    pps->numRefIdxDefault[0] = X265_MIN(m_param->maxNumReferences, MAX_NUM_REF - 1);@' encoder/encoder.cpp
        sed -i 's@^    pps->numRefIdxDefault\[1\] = 1;$@    pps->numRefIdxDefault[1] = 1 + !!m_param->bBPyramid;@' encoder/encoder.cpp

        # shallow clone has no tags; empty X265_LATEST_TAG breaks the RC list(GET) on Windows
        grep -q 'if(VERSION_LIST)' CMakeLists.txt || sed -i '/^    list(GET VERSION_LIST 0 X265_VERSION_MAJOR)$/,/^    list(GET VERSION_LIST 1 X265_VERSION_MINOR)$/c\
    if(VERSION_LIST)\
            list(GET VERSION_LIST 0 X265_VERSION_MAJOR)\
            list(GET VERSION_LIST 1 X265_VERSION_MINOR)\
        else()\
            set(X265_VERSION_MAJOR 0)\
            set(X265_VERSION_MINOR 0)\
        endif()' CMakeLists.txt

