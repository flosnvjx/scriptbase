#!/usr/bin/awk -f
# Portable SHA-256 in POSIX awk.
# Bit operations are emulated arithmetically.

BEGIN {
    # 0: abort only when input contains a wide char
    # 1: abort whenever gawk is in multibyte mode
    STRICT_BYTE_MODE = 0

    pow2_init()
    _init_bit_tables()
    _init_constants()
    _ord_init()
    _init_mode()
    _check_fp_portability()
}

# ----------------------------------------------------------------------
# Reject non-IEEE 754 floating point:
#   - VAX D/F/G float (NetBSD/VAX)
#   - IBM hex float (z/OS USS 31-bit FLOAT(HEX), S/360/S/370 native)
# AIX and z/OS 64-bit FLOAT(IEEE) use IEEE binary64 for double and pass.
# ----------------------------------------------------------------------
function _check_fp_portability(    h) {
    # IEEE binary64: normal range 2.2e-308 .. 1.8e308.
    # VAX D-float:   normal range 2.9e-39  .. 1.7e38.
    # IBM hex dbl:   normal range 5.4e-80  .. 7.2e75.
    # 1e-300 is normal on IEEE, underflows to 0 on VAX and IBM hex float.
    # Underflow-to-zero is the standard non-trapping behavior;
    # overflow (1e400) is not, hence the low-end probe only.
    if (!(1e-300 > 0))
        die("sha256.awk: non-IEEE 754 floating point detected " \
            "(e.g. VAX, IBM z/OS 31-bit FLOAT(HEX), S/360); aborting")
}

{
    content = content $0 "\n"
}

END {
    printf("SHA256= %s\n", sha256(content))
}

# ----------------------------------------------------------------------
# gawk / multibyte detection
# ----------------------------------------------------------------------
function _init_mode(    v) {
    IS_GAWK = (PROCINFO["version"] != "")
    MB_CUR_MAX = 1

    if (IS_GAWK) {
        v = PROCINFO["mb_cur_max"]
        if (v != "")
            MB_CUR_MAX = v + 0
    }

    if (IS_GAWK && MB_CUR_MAX > 1 && STRICT_BYTE_MODE)
        die("sha256.awk: gawk is in multibyte mode; " \
            "rerun with --characters-as-bytes or LC_ALL=C")
}

function die(msg) {
    print msg > "/dev/stderr"
    exit 1
}

# Refuse input that cannot be treated as a byte string.
# In non-strict mode this only rejects characters outside the 0..255 table.
function _check_input_bytes(s,    i, c) {
    if (!IS_GAWK || MB_CUR_MAX <= 1)
        return

    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (!(c in _ord_))
            die("sha256.awk: input contains a character wider than one byte; " \
                "rerun with --characters-as-bytes or LC_ALL=C")
    }
}

# ----------------------------------------------------------------------
# 2^n lookup
# ----------------------------------------------------------------------
function pow2_init(    i) {
    POW2[0] = 1
    for (i = 1; i <= 32; i++)
        POW2[i] = POW2[i-1] * 2
}

# ----------------------------------------------------------------------
# 4-bit AND / OR / XOR lookup tables (16x16 each)
# ----------------------------------------------------------------------
function _init_bit_tables(    av, bv, i, ab, bb, andr, orr, xorr) {
    for (av = 0; av < 16; av++) {
        for (bv = 0; bv < 16; bv++) {
            andr = 0; orr = 0; xorr = 0
            for (i = 0; i < 4; i++) {
                ab = int(av / POW2[i]) % 2
                bb = int(bv / POW2[i]) % 2
                if (ab && bb)      andr += POW2[i]
                if (ab || bb)      orr  += POW2[i]
                if (ab != bb)      xorr += POW2[i]
            }
            AND_T[av, bv] = andr
            OR_T[av, bv]  = orr
            XOR_T[av, bv] = xorr
        }
    }
}

# ----------------------------------------------------------------------
# SHA-256 round constants K[0..63]
# ----------------------------------------------------------------------
function _init_constants(    kstr, n, karr, i) {
    kstr = "428a2f98 71374491 b5c0fbcf e9b5dba5 3956c25b 59f111f1 923f82a4 ab1c5ed5 " \
           "d807aa98 12835b01 243185be 550c7dc3 72be5d74 80deb1fe 9bdc06a7 c19bf174 " \
           "e49b69c1 efbe4786 0fc19dc6 240ca1cc 2de92c6f 4a7484aa 5cb0a9dc 76f988da " \
           "983e5152 a831c66d b00327c8 bf597fc7 c6e00bf3 d5a79147 06ca6351 14292967 " \
           "27b70a85 2e1b2138 4d2c6dfc 53380d13 650a7354 766a0abb 81c2c92e 92722c85 " \
           "a2bfe8a1 a81a664b c24b8b70 c76c51a3 d192e819 d6990624 f40e3585 106aa070 " \
           "19a4c116 1e376c08 2748774c 34b0bcb5 391c0cb3 4ed8aa4a 5b9cca4f 682e6ff3 " \
           "748f82ee 78a5636f 84c87814 8cc70208 90befffa a4506ceb bef9a3f7 c67178f2"
    n = split(kstr, karr, " ")
    for (i = 1; i <= n; i++)
        K[i-1] = _hex2dec(karr[i])
}

function _hex2dec(h,    n, i, c, cv) {
    n = 0
    h = tolower(h)
    for (i = 1; i <= length(h); i++) {
        c = substr(h, i, 1)
        cv = index("0123456789abcdef", c) - 1
        n = n * 16 + cv
    }
    return n
}

function _tohex(n,    h, i, nib) {
    h = ""
    for (i = 7; i >= 0; i--) {
        nib = int(n / POW2[4*i]) % 16
        h = h substr("0123456789abcdef", nib + 1, 1)
    }
    return h
}

# ----------------------------------------------------------------------
# ord: char -> byte value
# ----------------------------------------------------------------------
function _ord_init(    i) {
    for (i = 0; i < 256; i++)
        _ord_[sprintf("%c", i)] = i
}
function ord(s) {
    return _ord_[substr(s, 1, 1)]
}

# ----------------------------------------------------------------------
# 32-bit bitwise ops via 4-bit lookup tables
# ----------------------------------------------------------------------
function and32(a, b,    r, s, av, bv) {
    r = 0
    for (s = 0; s < 32; s += 4) {
        av = int(a / POW2[s]) % 16
        bv = int(b / POW2[s]) % 16
        r += AND_T[av, bv] * POW2[s]
    }
    return r
}
function or32(a, b,    r, s, av, bv) {
    r = 0
    for (s = 0; s < 32; s += 4) {
        av = int(a / POW2[s]) % 16
        bv = int(b / POW2[s]) % 16
        r += OR_T[av, bv] * POW2[s]
    }
    return r
}
function xor32(a, b,    r, s, av, bv) {
    r = 0
    for (s = 0; s < 32; s += 4) {
        av = int(a / POW2[s]) % 16
        bv = int(b / POW2[s]) % 16
        r += XOR_T[av, bv] * POW2[s]
    }
    return r
}

function not32(a) {
    return xor32(a, 4294967295)
}

function lshift32(a, n) {
    if (n == 0) return a
    return (a % POW2[32-n]) * POW2[n]
}

function rshift32(a, n) {
    if (n == 0) return a
    return int(a / POW2[n])
}

function rotr32(a, n) {
    return or32(rshift32(a, n), lshift32(a, 32 - n))
}

function add32(a, b) {
    return (a + b) % 4294967296
}

# ----------------------------------------------------------------------
# SHA-256 main
# ----------------------------------------------------------------------
function sha256(input,    nbytes, i, nwords, j, a, b, c, d, e, f, g, h,
                        T1, T2, digest, S0, S1, ch, maj, s0, s1, w,
                        bit_len_hi, bit_len_lo, bytes, words, state, W) {

    # 1. string -> byte array
    _check_input_bytes(input)

    nbytes = length(input)
    for (i = 0; i < nbytes; i++)
        bytes[i] = ord(substr(input, i+1, 1))

    # 2. bytes -> big-endian 32-bit words
    nwords = 0
    for (i = 0; i < nbytes; i += 4) {
        w = 0
        for (j = 0; j < 4; j++) {
            w = w * 256
            if (i + j < nbytes)
                w += bytes[i + j]
        }
        words[nwords++] = w
    }

    # 3. padding
    bit_len_hi = int(nbytes * 8 / 4294967296)
    bit_len_lo = (nbytes * 8) % 4294967296

    if (nbytes % 4 == 0) {
        # append 0x80 as the highest byte of a fresh word
        words[nwords++] = POW2[31]
    } else {
        words[nwords - 1] += 128 * POW2[8 * (3 - nbytes % 4)]
    }

    while (nwords % 16 != 14)
        words[nwords++] = 0
    words[nwords++] = bit_len_hi
    words[nwords++] = bit_len_lo

    # 4. initial hash values
    state[0] = _hex2dec("6a09e667")
    state[1] = _hex2dec("bb67ae85")
    state[2] = _hex2dec("3c6ef372")
    state[3] = _hex2dec("a54ff53a")
    state[4] = _hex2dec("510e527f")
    state[5] = _hex2dec("9b05688c")
    state[6] = _hex2dec("1f83d9ab")
    state[7] = _hex2dec("5be0cd19")

    # 5. process each 512-bit block
    for (i = 0; i < nwords; i += 16) {
        for (j = 0; j < 16; j++)
            W[j] = words[i + j]
        for (j = 16; j < 64; j++) {
            s0 = xor32(xor32(rotr32(W[j-15], 7), rotr32(W[j-15], 18)),
                       rshift32(W[j-15], 3))
            s1 = xor32(xor32(rotr32(W[j-2], 17), rotr32(W[j-2], 19)),
                       rshift32(W[j-2], 10))
            W[j] = add32(add32(W[j-16], s0), add32(W[j-7], s1))
        }

        a = state[0]; b = state[1]; c = state[2]; d = state[3]
        e = state[4]; f = state[5]; g = state[6]; h = state[7]

        for (j = 0; j < 64; j++) {
            S1 = xor32(xor32(rotr32(e, 6), rotr32(e, 11)), rotr32(e, 25))
            ch = xor32(and32(e, f), and32(not32(e), g))
            T1 = add32(add32(add32(h, S1), add32(ch, K[j])), W[j])

            S0 = xor32(xor32(rotr32(a, 2), rotr32(a, 13)), rotr32(a, 22))
            maj = xor32(xor32(and32(a, b), and32(a, c)), and32(b, c))
            T2 = add32(S0, maj)

            h = g; g = f; f = e
            e = add32(d, T1)
            d = c; c = b; b = a
            a = add32(T1, T2)
        }

        state[0] = add32(state[0], a)
        state[1] = add32(state[1], b)
        state[2] = add32(state[2], c)
        state[3] = add32(state[3], d)
        state[4] = add32(state[4], e)
        state[5] = add32(state[5], f)
        state[6] = add32(state[6], g)
        state[7] = add32(state[7], h)
    }

    # 6. output hex digest
    digest = ""
    for (i = 0; i < 8; i++)
        digest = digest _tohex(state[i])
    return digest
}
