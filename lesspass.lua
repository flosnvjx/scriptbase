#!/usr/bin/env luajit
-- lesspass.lua - LessPass CLI port to LuaJIT (no FFI).
--
-- This is a drop-in replacement for the Python reference implementation
-- (lesspass.py v10.2.1).  Pure LuaJIT; no FFI.  Terminal echo control on
-- POSIX is emulated with `stty`.

local VERSION = "10.2.1"

-- ---------------------------------------------------------------------------
-- Environment detection & bit library
-- ---------------------------------------------------------------------------

local IS_POSIX = package.config:sub(1, 1) == "/"

local bit = require("bit")  -- LuaJIT
local band   = bit.band
local bor    = bit.bor
local bxor   = bit.bxor
local bnot   = bit.bnot
local rshift = bit.rshift
local ror    = bit.ror

local M32 = 4294967296
local unpack = table.unpack or unpack

-- ---------------------------------------------------------------------------
-- SHA-256 (pure LuaJIT)
-- ---------------------------------------------------------------------------

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function sha256_init()
    return {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}
end

local function sha256_process_block(state, block)
    local w = {}
    for i = 1, 16 do
        local b1, b2, b3, b4 = block:byte((i - 1) * 4 + 1, (i - 1) * 4 + 4)
        w[i] = (b1 * 16777216 + b2 * 65536 + b3 * 256 + b4) % M32
    end
    for i = 17, 64 do
        local w15 = w[i - 15]
        local w2  = w[i - 2]
        local s0 = bxor(ror(w15, 7), ror(w15, 18), rshift(w15, 3))
        local s1 = bxor(ror(w2, 17), ror(w2, 19), rshift(w2, 10))
        -- NOTE: no extra "+ w15" term here.
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % M32
    end

    local a, b, c, d = state[1], state[2], state[3], state[4]
    local e, f, g, h = state[5], state[6], state[7], state[8]

    for i = 1, 64 do
        local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = (h + S1 + ch + K[i] + w[i]) % M32
        local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        local t2 = (S0 + maj) % M32

        h = g; g = f; f = e
        e = (d + t1) % M32
        d = c; c = b; b = a
        a = (t1 + t2) % M32
    end

    state[1] = (state[1] + a) % M32
    state[2] = (state[2] + b) % M32
    state[3] = (state[3] + c) % M32
    state[4] = (state[4] + d) % M32
    state[5] = (state[5] + e) % M32
    state[6] = (state[6] + f) % M32
    state[7] = (state[7] + g) % M32
    state[8] = (state[8] + h) % M32
end

local function u32_to_bytes(v)
    v = v % M32
    return string.char(
        math.floor(v / 16777216) % 256,
        math.floor(v / 65536) % 256,
        math.floor(v / 256) % 256,
        v % 256
    )
end

local function sha256_finalize(state)
    local parts = {}
    for i = 1, 8 do
        parts[i] = u32_to_bytes(state[i])
    end
    return table.concat(parts)
end

-- prefix_len must be a multiple of 64 (state at a block boundary).
local function sha256_continue(state, prefix_len, msg)
    local msg_len   = #msg
    local total_len = prefix_len + msg_len
    local pad_len   = (64 - ((total_len + 9) % 64)) % 64
    local bit_len   = total_len * 8
    local high      = math.floor(bit_len / M32)
    local low       = bit_len % M32
    local padded = msg .. "\128" .. string.rep("\0", pad_len)
        .. u32_to_bytes(high) .. u32_to_bytes(low)
    for i = 1, #padded, 64 do
        sha256_process_block(state, padded:sub(i, i + 63))
    end
end

local function sha256(msg)
    local state = sha256_init()
    sha256_continue(state, 0, msg)
    return sha256_finalize(state)
end

-- ---------------------------------------------------------------------------
-- HMAC-SHA256 (with reusable ipad/opad states)
-- ---------------------------------------------------------------------------

local function hmac_prepare(key)
    if #key > 64 then key = sha256(key) end
    key = key .. string.rep("\0", 64 - #key)

    local ipad, opad = {}, {}
    for i = 1, 64 do
        local b = key:byte(i)
        ipad[i] = string.char(bxor(b, 0x36))
        opad[i] = string.char(bxor(b, 0x5c))
    end

    local ipad_state = sha256_init()
    sha256_process_block(ipad_state, table.concat(ipad))
    local opad_state = sha256_init()
    sha256_process_block(opad_state, table.concat(opad))
    return ipad_state, opad_state
end

local function copy_state(s)
    return {s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8]}
end

local function hmac_from_states(ipad_state, opad_state, msg)
    local istate = copy_state(ipad_state)
    sha256_continue(istate, 64, msg)
    local inner = sha256_finalize(istate)

    local ostate = copy_state(opad_state)
    sha256_continue(ostate, 64, inner)
    return sha256_finalize(ostate)
end

-- ---------------------------------------------------------------------------
-- PBKDF2-HMAC-SHA256
-- ---------------------------------------------------------------------------

local function pbkdf2_sha256(password, salt, iterations, dklen)
    local hlen    = 32
    local nblocks = math.ceil(dklen / hlen)
    local ipad_state, opad_state = hmac_prepare(password)
    local parts = {}

    for i = 1, nblocks do
        local block_index = u32_to_bytes(i)
        local u = hmac_from_states(ipad_state, opad_state, salt .. block_index)
        local t = {u:byte(1, hlen)}
        for _ = 2, iterations do
            u = hmac_from_states(ipad_state, opad_state, u)
            local ub = {u:byte(1, hlen)}
            for k = 1, hlen do
                t[k] = bxor(t[k], ub[k])
            end
        end
        parts[i] = string.char(unpack(t))
    end

    return table.concat(parts):sub(1, dklen)
end

-- ---------------------------------------------------------------------------
-- LessPass password derivation
-- ---------------------------------------------------------------------------

local CHARACTER_SUBSETS = {
    lowercase = "abcdefghijklmnopqrstuvwxyz",
    uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
    digits    = "0123456789",
    symbols   = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~",
}

local function remove_excluded_chars(str, exclude)
    if exclude == nil or exclude == "" then return str end
    local set = {}
    for i = 1, #exclude do
        set[exclude:sub(i, i)] = true
    end
    local out = {}
    for i = 1, #str do
        local c = str:sub(i, i)
        if not set[c] then out[#out + 1] = c end
    end
    if #out == 0 then error({tag = "exclude_all"}) end
    return table.concat(out)
end

local function get_set_of_characters(rules, exclude)
    if rules == nil then
        local pool = CHARACTER_SUBSETS.lowercase
            .. CHARACTER_SUBSETS.uppercase
            .. CHARACTER_SUBSETS.digits
            .. CHARACTER_SUBSETS.symbols
        return remove_excluded_chars(pool, exclude)
    end
    local parts = {}
    for i = 1, #rules do
        parts[i] = CHARACTER_SUBSETS[rules[i]]
    end
    return remove_excluded_chars(table.concat(parts), exclude)
end

-- big-int stored as 32 big-endian bytes; only division by small int is needed.
local function bigint_from_hex(hex_str)
    local bytes = {}
    for i = 1, 32 do
        bytes[i] = tonumber(hex_str:sub((i - 1) * 2 + 1, i * 2), 16) or 0
    end
    return bytes
end

local function bigint_divmod_small(bytes, divisor)
    local rem = 0
    for i = 1, 32 do
        local cur = rem * 256 + bytes[i]
        bytes[i] = math.floor(cur / divisor)
        rem = cur % divisor
    end
    return rem
end

local function consume_entropy(generated, entropy_bytes, set_of_characters, max_length)
    while #generated < max_length do
        local rem = bigint_divmod_small(entropy_bytes, #set_of_characters)
        generated = generated .. set_of_characters:sub(rem + 1, rem + 1)
    end
    return generated
end

local function get_one_char_per_rule(entropy_bytes, rules, exclude)
    local out = {}
    for i = 1, #rules do
        local available = remove_excluded_chars(CHARACTER_SUBSETS[rules[i]], exclude)
        local rem = bigint_divmod_small(entropy_bytes, #available)
        out[i] = available:sub(rem + 1, rem + 1)
    end
    return table.concat(out)
end

local function insert_string_pseudo_randomly(generated, entropy_bytes, extra)
    for i = 1, #extra do
        local letter = extra:sub(i, i)
        local rem = bigint_divmod_small(entropy_bytes, #generated)
        generated = generated:sub(1, rem) .. letter .. generated:sub(rem + 1)
    end
    return generated
end

local function get_configured_rules(profile)
    local order = {"lowercase", "uppercase", "digits", "symbols"}
    local rules = {}
    for i = 1, #order do
        if profile[order[i]] then rules[#rules + 1] = order[i] end
    end
    return rules
end

local function render_password(entropy_bytes, profile)
    local rules    = get_configured_rules(profile)
    local exclude  = profile.exclude or ""
    local set      = get_set_of_characters(rules, exclude)
    local password = consume_entropy("", entropy_bytes, set, profile.length - #rules)
    local extra    = get_one_char_per_rule(entropy_bytes, rules, exclude)
    return insert_string_pseudo_randomly(password, entropy_bytes, extra)
end

-- hex(n)[2:] (lowercase, no 0x prefix)
local function to_hex(n)
    local digits = "0123456789abcdef"
    local out = ""
    repeat
        local r = n % 16
        out = digits:sub(r + 1, r + 1) .. out
        n = math.floor(n / 16)
    until n == 0
    return out
end

local function generate_password(profile, master_password)
    local salt   = profile.site .. profile.login .. to_hex(profile.counter)
    local digest = pbkdf2_sha256(master_password, salt, 100000, 32)

    local hex_entropy = {}
    for i = 1, 32 do
        local b = digest:byte(i)
        hex_entropy[i] = string.format("%02x", b)
    end
    hex_entropy = table.concat(hex_entropy)

    local entropy_bytes = bigint_from_hex(hex_entropy)
    return render_password(entropy_bytes, profile)
end

-- ---------------------------------------------------------------------------
-- Terminal I/O
-- ---------------------------------------------------------------------------

local function run_shell(cmd)
    local a, _, code = os.execute(cmd)
    if a == true then return 0 end
    if type(a) == "number" then return a end
    return code or 1
end

local function isatty()
    if not IS_POSIX then return false end
    return run_shell("test -t 0 2>/dev/null") == 0
end

local function read_line_stdin()
    return io.stdin:read("*l")
end

local function read_line_with_prompt(prompt)
    io.stderr:write(prompt)
    io.stderr:flush()
    return read_line_stdin()
end

local function read_password_raw(prompt, echo_star)
    io.stderr:write(prompt)
    io.stderr:flush()

    run_shell("stty -icanon -echo -isig min 1 time 0 2>/dev/null")

    local chars  = {}
    local ctrl_c = false
    local eof    = false

    local ok, err = pcall(function()
        while true do
            local c = io.stdin:read(1)
            if not c then return end          -- stream EOF: keep partial
            local b = c:byte()
            if b == 3 then                    -- Ctrl+C (isig disabled)
                ctrl_c = true; return
            elseif b == 13 or b == 10 then    -- CR / LF
                return
            elseif b == 4 then                -- Ctrl+D
                if #chars == 0 then eof = true; return end
                -- otherwise ignore
            elseif b == 127 or b == 8 then    -- backspace / DEL
                if #chars > 0 then
                    table.remove(chars)
                    if echo_star then
                        io.stderr:write("\b \b")
                        io.stderr:flush()
                    end
                end
            else
                chars[#chars + 1] = c
                if echo_star then
                    io.stderr:write("*")
                    io.stderr:flush()
                end
            end
        end
    end)

    run_shell("stty sane 2>/dev/null")
    io.stderr:write("\n")
    io.stderr:flush()

    if not ok then error(err) end
    if ctrl_c then error({tag = "interrupt"}) end
    if eof    then error({tag = "eof"})       end
    return table.concat(chars)
end

local function read_secret(prompt, mask)
    if not isatty() then
        return read_line_with_prompt(prompt) or ""
    end
    if IS_POSIX then
        return read_password_raw(prompt, mask)
    end
    io.stderr:write("warning: cannot disable terminal echo; password will echo\n")
    io.stderr:flush()
    io.stderr:write(prompt)
    io.stderr:flush()
    return read_line_stdin() or ""
end

-- ---------------------------------------------------------------------------
-- CLI helpers
-- ---------------------------------------------------------------------------

local HELP_TEXT = string.format([[
LessPass %s - stateless password generator (LuaJIT port)

Usage:
  lesspass [SITE] [LOGIN] [MASTER_PASSWORD] [OPTIONS]

Options:
  -v, --version          Show version and exit
  -h, --help             Show this help and exit
  -F, --file FILE        Read master password from FILE ('-' for stdin)
      --ask              Interactively edit all three parameters
      --no-mask          Don't echo '*' while typing master password
                         (alias: --no-fingerprint)
  -L, --length N         Password length (default: 16, min: 5, max: 35)
  -C, --counter N        Password counter (default: 1)
      --exclude CHARS    Exclude these characters from generated password
  -l, --lowercase        Add lowercase to password
  -u, --uppercase        Add uppercase to password
  -d, --digits           Add digits to password
  -s, --symbols          Add symbols to password
      --no-lowercase     Remove lowercase from password
      --no-uppercase     Remove uppercase from password
      --no-digits        Remove digits from password
      --no-symbols       Remove symbols from password

Notes (differences from the Python reference implementation):
  * Pure LuaJIT, no FFI.  Masked interactive input is emulated with
    POSIX 'stty'; on non-POSIX platforms, or when 'stty' is unavailable,
    the master password is read with echo and a warning is printed.
  * During a masked prompt, Ctrl+C (byte 0x03) aborts cleanly with
    exit code 130 and runs `stty sane` before exiting.  Ctrl+Z / Ctrl+\
    are disabled while the prompt is active.
  * SITE, LOGIN and MASTER_PASSWORD accept any alphanumeric, punctuation,
    or space characters.  When the master password is read from a file
    (-F FILE) or stdin (-F -), HTAB, CR, and LF are preserved verbatim.
    Interactive master-password entry terminates on CR/LF.
  * Files are read as raw bytes: no encoding conversion, no newline
    translation.  (Python's text mode on Windows would normalise CRLF.)
  * String length uses byte counts, not Unicode codepoints; --exclude of
    non-ASCII bytes is best avoided.

Examples:
  lesspass site login masterpassword
  lesspass site login masterpassword -L 20 -d
  lesspass --ask
  echo "mypass" | lesspass site login -F -
]], VERSION)

local function die(msg, code)
    io.stderr:write(msg)
    io.stderr:flush()
    os.exit(code or 2)
end

local function parse_args(argv)
    local args = {
        ask = false, no_mask = false,
        length = nil, counter = nil, exclude = nil,
        lowercase = false, uppercase = false, digits = false, symbols = false,
        no_lowercase = false, no_uppercase = false, no_digits = false, no_symbols = false,
        master_password_file = nil,
        site = nil, login = nil, master_password = nil,
    }
    local positionals = {}
    local i, n = 1, #argv
    local no_more_options = false

    local function arg_missing(opt)
        die("error: option requires an argument: " .. opt
            .. "\nRun with --help for usage.\n")
    end
    local function unrecognized(a)
        die("error: unrecognized argument: " .. a
            .. "\nRun with --help for usage.\n")
    end

    while i <= n do
        local a = argv[i]
        if no_more_options then
            positionals[#positionals + 1] = a
        elseif a == "-h" or a == "--help" then
            io.stdout:write(HELP_TEXT); io.stdout:flush(); os.exit(0)
        elseif a == "-v" or a == "--version" then
            io.stdout:write(VERSION .. "\n"); io.stdout:flush(); os.exit(0)
        elseif a == "--ask" then
            args.ask = true
        elseif a == "--no-mask" or a == "--no-fingerprint" then
            args.no_mask = true
        elseif a == "-l" or a == "--lowercase" then
            args.lowercase = true
        elseif a == "-u" or a == "--uppercase" then
            args.uppercase = true
        elseif a == "-d" or a == "--digits" then
            args.digits = true
        elseif a == "-s" or a == "--symbols" then
            args.symbols = true
        elseif a == "--no-lowercase" then
            args.no_lowercase = true
        elseif a == "--no-uppercase" then
            args.no_uppercase = true
        elseif a == "--no-digits" then
            args.no_digits = true
        elseif a == "--no-symbols" then
            args.no_symbols = true
        elseif a == "--" then
            no_more_options = true
        elseif a == "-F" or a == "--file" then
            i = i + 1; if i > n then arg_missing(a) end
            args.master_password_file = argv[i]
        elseif a:sub(1, 7) == "--file=" then
            args.master_password_file = a:sub(8)
        elseif a:sub(1, 2) == "-F" and #a > 2 then
            args.master_password_file = a:sub(3)
        elseif a == "-L" or a == "--length" then
            i = i + 1; if i > n then arg_missing(a) end
            args.length = argv[i]
        elseif a:sub(1, 9) == "--length=" then
            args.length = a:sub(10)
        elseif a:sub(1, 2) == "-L" and #a > 2 then
            args.length = a:sub(3)
        elseif a == "-C" or a == "--counter" then
            i = i + 1; if i > n then arg_missing(a) end
            args.counter = argv[i]
        elseif a:sub(1, 10) == "--counter=" then
            args.counter = a:sub(11)
        elseif a:sub(1, 2) == "-C" and #a > 2 then
            args.counter = a:sub(3)
        elseif a == "--exclude" then
            i = i + 1; if i > n then arg_missing(a) end
            args.exclude = argv[i]
        elseif a:sub(1, 10) == "--exclude=" then
            args.exclude = a:sub(11)
        elseif a:sub(1, 1) == "-" and #a > 1 then
            unrecognized(a)
        else
            positionals[#positionals + 1] = a
        end
        i = i + 1
    end

    if #positionals > 3 then
        die("error: too many positional arguments\nRun with --help for usage.\n")
    end
    args.site            = positionals[1]
    args.login           = positionals[2]
    args.master_password = positionals[3]

    if args.length == nil then
        args.length = 16
    else
        local v = tonumber(args.length)
        if v == nil or v ~= math.floor(v) then
            die("error: length must be an integer\n")
        end
        if v < 5 or v > 35 then
            die("error: length is out of range, choose in [5-35]\n")
        end
        args.length = v
    end

    if args.counter == nil then
        args.counter = 1
    else
        local v = tonumber(args.counter)
        if v == nil or v ~= math.floor(v) then
            die("error: counter must be an integer\n")
        end
        args.counter = v
    end

    return args
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

local function _main(argv)
    local args = parse_args(argv)
    local stdin_available = isatty()

    if args.master_password_file ~= nil and args.master_password ~= nil then
        die("error: master password supplied both as a positional argument "
            .. "and via -F; choose one\n")
    end
    if args.ask and args.master_password_file == "-" then
        die("error: --ask cannot be combined with -F - because -F - consumes stdin\n")
    end

    -- -F resolution (read raw bytes; newlines and HTAB preserved)
    if args.master_password_file == "-" then
        args.master_password      = io.stdin:read("*a") or ""
        args.master_password_file = nil
        stdin_available           = false
    elseif args.master_password_file then
        local f, err = io.open(args.master_password_file, "rb")
        if not f then
            die("error: cannot read master password file: "
                .. tostring(err) .. "\n", 1)
        end
        args.master_password = f:read("*a") or ""
        f:close()
    end

    -- --ask: interactive editing of all three (blank keeps current)
    if args.ask then
        if not stdin_available then
            die("error: --ask requires an interactive terminal\n", 1)
        end

        local function prompt_edit(field, label, cur)
            if cur ~= nil then
                io.stderr:write(label .. " [" .. cur .. "]: ")
            else
                io.stderr:write(label .. ": ")
            end
            io.stderr:flush()
            local s = read_line_stdin() or ""
            s = s:match("^%s*(.-)%s*$")
            if s == "" and cur ~= nil then return cur end
            return s
        end

        args.site  = prompt_edit("site",  "Site",  args.site)
        if args.site == "" then die("error: Site is required\n", 1) end
        args.login = prompt_edit("login", "Login", args.login)
        if args.login == "" then die("error: Login is required\n", 1) end

        local mp
        if args.master_password ~= nil then
            mp = read_secret(
                "Master Password (leave blank to keep current): ",
                not args.no_mask)
            if mp == "" then mp = args.master_password end
        else
            mp = read_secret("Master Password: ", not args.no_mask)
        end
        if mp == "" then die("error: Master Password is required\n", 1) end
        args.master_password = mp
    end

    local function resolve(name, value, secret)
        if value ~= nil then return value end
        if stdin_available then
            local v
            if secret then
                v = read_secret(name .. ": ", not args.no_mask)
            else
                io.stderr:write(name .. ": ")
                io.stderr:flush()
                v = read_line_stdin()
                v = (v or ""):match("^%s*(.-)%s*$")
            end
            if v ~= nil and v ~= "" then return v end
        end
        die("error: " .. name
            .. " is required (not provided and cannot prompt)\n", 4)
    end

    local site            = resolve("Site",            args.site,            false)
    local login           = resolve("Login",           args.login,           false)
    local master_password = resolve("Master Password", args.master_password, true)

    -- Character set selection (default: all four).
    local positive_flags =
        args.lowercase or args.uppercase or args.digits or args.symbols
    local profile
    if positive_flags then
        profile = {
            lowercase = args.lowercase, uppercase = args.uppercase,
            digits    = args.digits,    symbols   = args.symbols,
        }
    else
        profile = {lowercase = true, uppercase = true,
                   digits = true, symbols = true}
    end
    if args.no_lowercase then profile.lowercase = false end
    if args.no_uppercase then profile.uppercase = false end
    if args.no_digits    then profile.digits    = false end
    if args.no_symbols   then profile.symbols   = false end

    if not (profile.lowercase or profile.uppercase
            or profile.digits or profile.symbols) then
        die("error: you can't exclude all chars available\n", 6)
    end

    profile.site    = site
    profile.login   = login
    profile.counter = args.counter
    profile.length  = args.length
    if args.exclude ~= nil then profile.exclude = args.exclude end

    local ok, result = pcall(generate_password, profile, master_password)
    if not ok then
        if type(result) == "table" and result.tag == "exclude_all" then
            die("error: you can't exclude all chars available\n", 6)
        end
        error(result)
    end

    io.stdout:write(result .. "\n")
    io.stdout:flush()
end

local function main()
    local ok, err = pcall(function() _main(arg) end)
    if ok then return end
    if type(err) == "table" then
        if err.tag == "interrupt" then
            os.exit(130)   -- read_password_raw already emitted a newline
        elseif err.tag == "eof" then
            os.exit(1)
        end
    end
    io.stderr:write(tostring(err) .. "\n")
    os.exit(1)
end

if arg and arg[0] then
    main()
end
