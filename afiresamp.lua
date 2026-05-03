#!/usr/bin/env luajit
-- SPDX-FileCopyrightText: 2026 DeepSeek LLM
-- SPDX-License-Identifier: WTFPL
-- vim: set noet ts=2 sw=2 sts=2:
--
-- implemented based on soxpiperesample.py

---
-- afiresamp – resample audio from stdin to 44.1k/48k with clipping protection.
--
-- Usage:
--   afiresamp.lua [-V <level>] [44100|48000]
--
-- Options:
--   -V <level>     Set FFmpeg log level: quiet, error, warning, info, debug.
--                  Default is warning.
--   [44100|48000]  Target sample rate.  Default is 44100.
--
-- It reads audio from stdin (pipe or regular file), determines the exact attenuation needed to prevent clipping after resampling to both the target rate (dithering got applied after that if needed) and then to the opposite rate (48000 Hz when target is 44100, or vice‑versa)
--
-- No temporary files are created. Pipe input is buffered in a memfd.
-- It has detection on upsampled (bit-depth) input.
--
-- The script prints a summary line to stderr (only when stderr is a terminal)
-- and the final audio data (16‑bit WAV stream) to stdout.  Errors go to stderr.
---

-- workflow inspired by:
-- * https://hydrogenaudio.org/index.php?topic=126615.msg1058178#msg1058178
-- * https://hydrogenaudio.org/index.php/topic,63360.0.html

local ffi = require("ffi")
local bit = require("bit")
local C = ffi.C

ffi.cdef[[
typedef struct AVCodecContext AVCodecContext;
typedef struct AVFormatContext AVFormatContext;
typedef struct AVStream AVStream;
typedef struct AVCodec AVCodec;
typedef struct AVPacket AVPacket;
typedef struct AVFrame AVFrame;
typedef struct AVChannelLayout AVChannelLayout;
typedef struct SwrContext SwrContext;
typedef struct AVIOContext AVIOContext;

// Logging
void av_log_set_level(int level);
void av_log_set_callback(void (*callback)(void*, int, const char*, va_list));
int av_log_get_level(void);

// avutil
int av_strerror(int errnum, char *errbuf, size_t errbuf_size);
void *av_malloc(size_t size);
void av_free(void *ptr);
const char *av_get_sample_fmt_name(int sample_fmt);

// avformat
AVFormatContext *avformat_alloc_context(void);
void avformat_free_context(AVFormatContext *s);
int avformat_open_input(AVFormatContext **ps, const char *url, void *fmt, void **options);
void avformat_close_input(AVFormatContext **s);
int avformat_find_stream_info(AVFormatContext *ic, void **options);
int av_find_best_stream(AVFormatContext *ic, int type, int wanted, int related, const AVCodec **decoder, int flags);
int av_read_frame(AVFormatContext *s, AVPacket *pkt);

// avcodec
AVCodecContext *avcodec_alloc_context3(const AVCodec *codec);
int avcodec_open2(AVCodecContext *avctx, const AVCodec *codec, void **options);
int avcodec_close(AVCodecContext *avctx);
void avcodec_free_context(AVCodecContext **avctx);
int avcodec_parameters_to_context(AVCodecContext *codec, const void *par);
AVPacket *av_packet_alloc(void);
void av_packet_free(AVPacket **pkt);
void av_packet_unref(AVPacket *pkt);
int avcodec_send_packet(AVCodecContext *avctx, const AVPacket *avpkt);
int avcodec_receive_frame(AVCodecContext *avctx, AVFrame *frame);
AVFrame *av_frame_alloc(void);
void av_frame_free(AVFrame **frame);

// swresample
SwrContext *swr_alloc(void);
int swr_init(SwrContext *s);
void swr_free(SwrContext **s);
int swr_convert(SwrContext *s, uint8_t **out, int out_count,
                const uint8_t **in, int in_count);
int swr_convert_frame(SwrContext *s, AVFrame *out, const AVFrame *in);
]]

ffi.cdef[[
int swr_alloc_set_opts2(SwrContext **ps,
                        const AVChannelLayout *out_ch_layout, int out_sample_fmt, int out_sample_rate,
                        const AVChannelLayout *in_ch_layout, int in_sample_fmt, int in_sample_rate,
                        int log_offset, void *log_ctx);
]]

-- channel layout (added after swr_alloc_set_opts2 to avoid forward reference issues)
ffi.cdef[[
int av_channel_layout_from_mask(AVChannelLayout *ch_layout, uint64_t mask);
int av_channel_layout_copy(AVChannelLayout *dst, const AVChannelLayout *src);
void av_channel_layout_uninit(AVChannelLayout *ch_layout);
int av_frame_get_buffer(AVFrame *frame, int align);
]]

-- AVIO custom
ffi.cdef[[
AVIOContext *avio_alloc_context(unsigned char *buffer, int buffer_size,
                                int write_flag, void *opaque,
                                int (*read_packet)(void *opaque, uint8_t *buf, int buf_size),
                                int (*write_packet)(void *opaque, const uint8_t *buf, int buf_size),
                                int64_t (*seek)(void *opaque, int64_t offset, int whence));
void avio_context_free(AVIOContext **ps);
]]

-- memfd and mmap (Linux)
ffi.cdef[[
int memfd_create(const char *name, unsigned int flags);
void *mmap(void *addr, size_t length, int prot, int flags, int fd, long long offset);
int munmap(void *addr, size_t length);
long long lseek(int fd, long long offset, int whence);
ssize_t write(int fd, const void *buf, size_t count);
int close(int fd);
]]

-- Load libraries
local libavutil = ffi.load("avutil")
local libavformat = ffi.load("avformat")
local libavcodec = ffi.load("avcodec")
local libswresample = ffi.load("swresample")
local libsoxr = ffi.load("soxr")

-- Log levels
local AV_LOG_QUIET   = -8
local AV_LOG_ERROR   = 16
local AV_LOG_WARNING = 24
local AV_LOG_INFO    = 32
local AV_LOG_DEBUG   = 48

local log_levels = {
  quiet   = AV_LOG_QUIET,
  error   = AV_LOG_ERROR,
  warning = AV_LOG_WARNING,
  info    = AV_LOG_INFO,
  debug   = AV_LOG_DEBUG,
}

-- Sample format constants (enum AVSampleFormat)
local AV_SAMPLE_FMT_U8   = 0
local AV_SAMPLE_FMT_S16  = 1
local AV_SAMPLE_FMT_S32  = 2
local AV_SAMPLE_FMT_FLT  = 3
local AV_SAMPLE_FMT_DBL  = 4
local AV_SAMPLE_FMT_U8P  = 5
local AV_SAMPLE_FMT_S16P = 6
local AV_SAMPLE_FMT_S32P = 7
local AV_SAMPLE_FMT_FLTP = 8
local AV_SAMPLE_FMT_DBLP = 9

local AVMEDIA_TYPE_AUDIO = 1


--
-- Return true if the input sample format represents a bit depth greater
-- than 16.  Dither is only needed when we are truncating higher‑precision
-- samples to 16 bits; expanding 8‑bit to 16‑bit does not require dither.
--
local function if_sampl_gt_16bit(sample_fmt)
  return (sample_fmt == AV_SAMPLE_FMT_S32 or sample_fmt == AV_SAMPLE_FMT_S32P or
          sample_fmt == AV_SAMPLE_FMT_FLT or sample_fmt == AV_SAMPLE_FMT_FLTP or
          sample_fmt == AV_SAMPLE_FMT_DBL or sample_fmt == AV_SAMPLE_FMT_DBLP)
end

--
-- Inspect the decoded float buffer frame‑by‑frame to decide whether the
-- true bit depth exceeds 16 bits.  The container format alone may claim
-- >16 bits while the actual audio has been upsampled from a lower bit
-- depth (e.g. 8‑bit → 16‑bit, or 16‑bit → 24‑bit with zero padding).
--
-- A *frame* (every channel at a single sample instant) is considered
-- “high‑depth” if **any** channel in that frame shows >16‑bit activity.
-- The detection for a single channel value depends on the container:
--
--   * 32‑bit integer containers (S32 / S32P):
--     the lower 16 bits of the 32‑bit integer representation are non‑zero.
--
--   * float / double containers (FLT, FLTP, DBL, DBLP):
--     |sample * 32768 - round(sample * 32768)| > 1e-6, i.e. the sample
--     carries information beyond the 1/32768 quantisation grid of 16‑bit
--     audio.
--
-- The scan tracks *consecutive* high‑depth frames.  If a run reaches
-- `threshold` frames (default 600, ≈13.6 ms at 44.1 kHz), the audio is
-- deemed to have genuine >16‑bit content and dithering will be applied.
-- Shorter runs are treated as upsampling artefacts and **do not** trigger
-- dithering.  The scan returns as soon as a qualifying run is encountered.
--
-- Returns true if dither is still required, false if the effective bit
-- depth is ≤16 and dither should be skipped.
--
local function detect_effective_bits(buf, total_samples, channels, sample_fmt)
  local threshold = 600          -- minimum consecutive high‑depth frames
  local run = 0                  -- current consecutive count

  -- helper: returns true if the channel sample has >16‑bit information
  local function is_high_depth(val)
    if sample_fmt == AV_SAMPLE_FMT_S32 or sample_fmt == AV_SAMPLE_FMT_S32P then
      if val < -1.0 then val = -1.0 end
      if val > 1.0 then val = 1.0 end
      -- Round symmetrically: use 2^31-1 scaling, then integer rounding.
      local intval = val >= 0 and math.floor(val * 2147483647.0 + 0.5) or math.ceil(val * 2147483647.0 - 0.5)
      return bit.band(intval, 0xFFFF) ~= 0
    end
    if sample_fmt == AV_SAMPLE_FMT_FLT or sample_fmt == AV_SAMPLE_FMT_FLTP or
       sample_fmt == AV_SAMPLE_FMT_DBL or sample_fmt == AV_SAMPLE_FMT_DBLP then
      local v = val * 32768.0
      return math.abs(v - math.floor(v + 0.5)) > 1e-6
    end
    -- unknown format: be conservative
    return true
  end

  -- examine every frame (sample instant) across all channels
  for frame_idx = 0, total_samples - 1 do
    local frame_is_high = false
    for ch = 0, channels - 1 do
      if is_high_depth(buf[frame_idx * channels + ch]) then
        frame_is_high = true
        break
      end
    end
    if frame_is_high then
      run = run + 1
      if run >= threshold then
        return true    -- genuine >16‑bit content detected
      end
    else
      run = 0
    end
  end

  return false   -- no sustained high‑depth run found
end

-- Logging callback
local current_log_level = AV_LOG_WARNING

local function set_log_level(level_name)
  local lvl = log_levels[level_name]
  if not lvl then
    io.stderr:write("Unknown log level: " .. level_name .. "\n")
    os.exit(1)
  end
  current_log_level = lvl
end

local log_cb = ffi.cast("void (*)(void*, int, const char*, va_list)",
  function(avcl, level, fmt, va)
    if level > current_log_level then return end
    local buf = ffi.new("char[?]", 4096)
    C.vsnprintf(buf, 4096, fmt, va)
    local msg = ffi.string(buf):gsub("\n$", "")
    io.stderr:write(string.format("[ffmpeg %d] %s\n", level, msg))
  end)
libavutil.av_log_set_callback(log_cb)

-- ---------------------------------------------------------------------------
-- Command line parsing
local function parse_args()
  local target_rate = 44100
  local args = {}
  for i = 1, #arg do args[#args+1] = arg[i] end

  local i = 1
  while i <= #args do
    if args[i] == "-V" then
      i = i + 1
      if i > #args then
        io.stderr:write("Missing log level after -V\n")
        os.exit(1)
      end
      set_log_level(args[i])
    elseif args[i]:match("^%d+$") then
      local r = tonumber(args[i])
      if r == 44100 or r == 48000 then
        target_rate = r
      else
        io.stderr:write("Target rate must be 44100 or 48000\n")
        os.exit(1)
      end
    else
      io.stderr:write("Unknown argument: " .. args[i] .. "\n")
      io.stderr:write("Usage: " .. arg[0] .. " [-V quiet|error|warning|info|debug] [44100|48000]\n")
      os.exit(1)
    end
    i = i + 1
  end
  return target_rate
end

-- ---------------------------------------------------------------------------
-- Input detection
local function get_input()
  local fd = 0 -- stdin
  if C.lseek(fd, 0, 1) >= 0 then   -- SEEK_CUR = 1
    -- Seekable (regular file), use /proc/self/fd/<fd> path
    local path = "/proc/self/fd/0"
    return "file", path
  end

  -- Aborting early if stdin is a tty (no data will ever arrive)
  if ffi.C.isatty(fd) then
    io.stderr:write("Error: stdin must be a pipe or file\n")
    os.exit(1)
  end

  local data = {}
  local total = 0
  while true do
    local chunk = io.stdin:read(65536)
    if not chunk then break end
    total = total + #chunk
    table.insert(data, chunk)
  end
  if total == 0 then
    io.stderr:write("No input data\n")
    os.exit(1)
  end

  local memfd = C.memfd_create("afiresamp", 0)
  if memfd < 0 then
    io.stderr:write("Failed to create memfd\n")
    os.exit(1)
  end

  local write_ok = true
  for _, chunk in ipairs(data) do
    local len = #chunk
    local written = C.write(memfd, chunk, len)
    if written ~= len then
      -- Don't abort inside the loop; close and exit after reporting all failures
      if write_ok then
        io.stderr:write("Failed to write to memfd\n")
        write_ok = false
      end
      break
    end
  end
  local buf = C.mmap(nil, total, 1, 2, memfd, 0)  -- PROT_READ=1, MAP_PRIVATE=2
  if buf == ffi.C.voidp(-1) then
    io.stderr:write("mmap failed\n")
    C.close(memfd)
    os.exit(1)
  end
  C.close(memfd)
  if not write_ok then
    C.munmap(buf, total)
    os.exit(1)
  end
  return "pipe", buf, total
end
-- ---------------------------------------------------------------------------
-- Custom AVIO from memory buffer
local function create_mem_avio(buf, size)
  local state = ffi.new("struct { uint8_t *buf; size_t size; size_t pos; }")
  state.buf = ffi.cast("uint8_t*", buf)
  state.size = size
  state.pos = 0

  local read_cb = ffi.cast("int (*)(void*, uint8_t*, int)", function(opaque, dest, dest_size)
    local s = ffi.cast("typeof(state)*", opaque)
    local remaining = s.size - s.pos
    local bytes = math.min(dest_size, remaining)
    if bytes == 0 then return 0 end
    ffi.copy(dest, s.buf + s.pos, bytes)
    s.pos = s.pos + bytes
    return bytes
  end)
  local seek_cb = ffi.cast("int64_t (*)(void*, int64_t, int)", function(opaque, offset, whence)
    local s = ffi.cast("typeof(state)*", opaque)
    local new_pos
    if whence == 0 then new_pos = offset
    elseif whence == 1 then new_pos = s.pos + offset
    elseif whence == 2 then new_pos = s.size + offset
    else return -1 end
    if new_pos < 0 or new_pos > s.size then return -1 end
    s.pos = new_pos
    return new_pos
  end)

  local avio_buf = ffi.new("unsigned char[?]", 4096)
  local ctx = C.avio_alloc_context(avio_buf, 4096, 0, state, read_cb, nil, seek_cb)
  return ctx, state
end

-- ---------------------------------------------------------------------------
-- Open input and return format context (also returns AVIOContext for pipe cleanup)
local function open_input(input_type, arg1, arg2)
  local fmt_ctx_p = ffi.new("AVFormatContext*[1]")
  local avio_ctx = nil
  local ret

  if input_type == "file" then
    ret = libavformat.avformat_open_input(fmt_ctx_p, arg1, nil, nil)
  else
    avio_ctx, _ = create_mem_avio(arg1, arg2)
    if not avio_ctx then
      io.stderr:write("Failed to create AVIOContext\n")
      return nil, nil, false
    end
    local fmt_ctx = C.avformat_alloc_context()
    fmt_ctx.pb = avio_ctx
    ret = libavformat.avformat_open_input(fmt_ctx_p, nil, nil, nil)
    if ret < 0 then
      C.avformat_free_context(fmt_ctx)
    else
      fmt_ctx_p[0] = fmt_ctx
    end
  end
  if ret < 0 then
    local errbuf = ffi.new("char[256]")
    libavutil.av_strerror(ret, errbuf, 256)
    io.stderr:write("Failed to open input: ", ffi.string(errbuf), "\n")
    return nil, nil, false
  end

  ret = libavformat.avformat_find_stream_info(fmt_ctx_p[0], nil)
  if ret < 0 then
    io.stderr:write("Could not find stream info\n")
    libavformat.avformat_close_input(fmt_ctx_p)
    return nil, nil, false
  end
  return fmt_ctx_p, avio_ctx, true
end

-- ---------------------------------------------------------------------------
-- Probe audio stream info (reopens input; returns sample_rate, fmt_name, codec_name)
local function probe_input(input_type, arg1, arg2)
  local fmt_ctx_p, avio_ctx, ok = open_input(input_type, arg1, arg2)
  if not ok then os.exit(1) end

  local decoder = ffi.new("const AVCodec*[1]")
  local sample_fmt  -- keep raw format value for if_sampl_gt_16bit()
  local idx = libavformat.av_find_best_stream(fmt_ctx_p[0], AVMEDIA_TYPE_AUDIO, -1, -1, decoder, 0)
  if idx < 0 then
    io.stderr:write("No audio stream found\n")
    libavformat.avformat_close_input(fmt_ctx_p)
    os.exit(1)
  end

  local stream = fmt_ctx_p[0].streams[idx]
  local codecpar = stream.codecpar
  local sample_rate = codecpar.sample_rate
  sample_fmt = codecpar.format
  local sample_fmt_name = ffi.string(libavutil.av_get_sample_fmt_name(sample_fmt)) or "unknown"
  local codec_name = decoder[0] ~= nil and ffi.string(decoder[0].name) or "unknown"

  libavformat.avformat_close_input(fmt_ctx_p)
  return sample_rate, sample_fmt_name, sample_fmt, codec_name
end
-- ---------------------------------------------------------------------------
-- Decode audio to interleaved float array
local function decode_audio(input_type, arg1, arg2)
  local fmt_ctx_p, avio_ctx, ok = open_input(input_type, arg1, arg2)
  if not ok then return nil, 0, 0 end

  local decoder = ffi.new("const AVCodec*[1]")
  local audio_idx = libavformat.av_find_best_stream(fmt_ctx_p[0], AVMEDIA_TYPE_AUDIO, -1, -1, decoder, 0)
  if audio_idx < 0 then
    io.stderr:write("No audio stream\n")
    libavformat.avformat_close_input(fmt_ctx_p)
    return nil, 0, 0
  end

  local stream = fmt_ctx_p[0].streams[audio_idx]
  local codec = decoder[0]
  local codec_ctx = C.avcodec_alloc_context3(codec)
  if not codec_ctx then
    io.stderr:write("Could not allocate codec context\n")
    libavformat.avformat_close_input(fmt_ctx_p)
    return nil, 0, 0
  end

  local ret = C.avcodec_parameters_to_context(codec_ctx, stream.codecpar)
  if ret < 0 then
    io.stderr:write("Failed to copy codec params\n")
    C.avcodec_free_context(codec_ctx)
    libavformat.avformat_close_input(fmt_ctx_p)
    return nil, 0, 0
  end

  ret = C.avcodec_open2(codec_ctx, codec, nil)
  if ret < 0 then
    io.stderr:write("Could not open codec\n")
    C.avcodec_free_context(codec_ctx)
    libavformat.avformat_close_input(fmt_ctx_p)
    return nil, 0, 0
  end

  if channels <= 0 or channels > 256 then
    io.stderr:write("Invalid channel count: ", tostring(channels), "\n")
    os.exit(1)
  end

  local swr = C.swr_alloc()
	local out_ch_layout = ffi.new("AVChannelLayout")
  local in_ch_layout = ffi.new("AVChannelLayout")
  C.av_channel_layout_copy(out_ch_layout, codec_ctx.ch_layout)
  C.av_channel_layout_copy(in_ch_layout, codec_ctx.ch_layout)

  ret = C.swr_alloc_set_opts2(swr,
    out_ch_layout, AV_SAMPLE_FMT_FLT, codec_ctx.sample_rate,
    in_ch_layout, codec_ctx.sample_fmt, codec_ctx.sample_rate,
    0, nil)
  if ret < 0 then
    io.stderr:write("Failed to set swresample options\n")
    C.swr_free(swr)
    C.avcodec_free_context(codec_ctx)
    libavformat.avformat_close_input(fmt_ctx_p)
    return nil, 0, 0
  end

  ret = C.swr_init(swr)
  if ret < 0 then
    io.stderr:write("Failed to init swresample\n")
    C.swr_free(swr)
    C.avcodec_free_context(codec_ctx)
    libavformat.avformat_close_input(fmt_ctx_p)
    return nil, 0, 0
  end

  local pkt = C.av_packet_alloc()
  local frame = C.av_frame_alloc()
  local samples = {}   -- Lua table to collect floats
  local total_samples = 0
  local channels = codec_ctx.ch_layout.nb_channels

  while C.av_read_frame(fmt_ctx_p[0], pkt) >= 0 do
    if pkt.stream_index == audio_idx then
      ret = C.avcodec_send_packet(codec_ctx, pkt)
      if ret < 0 then break end
      while true do
        ret = C.avcodec_receive_frame(codec_ctx, frame)
        if ret == -11 then break end   -- EAGAIN
        if ret < 0 then break end
        local out_frame = C.av_frame_alloc()
        out_frame.sample_rate = codec_ctx.sample_rate
        C.av_channel_layout_copy(out_frame.ch_layout, out_ch_layout)
        out_frame.format = AV_SAMPLE_FMT_FLT
        out_frame.nb_samples = frame.nb_samples
        -- allocate data buffer for output if not already done
        if out_frame.buf[0] == nil then
          C.av_frame_get_buffer(out_frame, 0)
        end
        local ret = C.swr_convert_frame(swr, out_frame, frame)
        if ret < 0 then
          C.av_frame_free(out_frame)
          break
        end
        local ns = out_frame.nb_samples
        local ptr = ffi.cast("float*", out_frame.data[0])
        for i = 0, ns * channels - 1 do
          samples[#samples + 1] = ptr[i]
        end
        total_samples = total_samples + ns
        C.av_frame_free(out_frame)
      end
    end
    C.av_packet_unref(pkt)
  end

  C.av_frame_free(frame)
  C.av_packet_free(pkt)
  C.swr_free(swr)
  C.avcodec_free_context(codec_ctx)
  libavformat.avformat_close_input(fmt_ctx_p)

  if total_samples == 0 then
    return ffi.new("float[0]"), 0, channels
  end

  local fbuf = ffi.new("float[?]", total_samples * channels)
	for i = 1, #samples do fbuf[i-1] = samples[i] end
  return fbuf, total_samples, channels
end

-- ---------------------------------------------------------------------------
-- libsoxr declarations (already done above, but double-check)
ffi.cdef[[
typedef struct soxr *soxr_t;
typedef const char *soxr_error_t;

typedef struct {
  double   io_ratio;
  unsigned max_io_buf;
  unsigned latency;
  unsigned flags;
} soxr_io_spec_t;

typedef struct {
  unsigned long precision;
  unsigned long passband_end;
  unsigned long stopband_begin;
  unsigned long phase_response;
  unsigned long flags;
  unsigned long op;
} soxr_quality_spec_t;

enum {
  SOXR_LINEAR_IIR = 0,
  SOXR_LINEAR_FIR = 1,
  SOXR_QQ = 0,
  SOXR_LQ = 1,
  SOXR_MQ = 2,
  SOXR_HQ = 3,
  SOXR_VHQ = 4,
};

soxr_t soxr_create(
  double input_rate,
  double output_rate,
  unsigned num_channels,
  soxr_error_t *error,
  const soxr_io_spec_t *io_spec,
  const soxr_quality_spec_t *quality_spec,
  void *user_data);

soxr_error_t soxr_process(
  soxr_t resampler,
  const float *input,
  size_t input_length,
  size_t *input_used,
  float *output,
  size_t output_length,
  size_t *output_generated);

void soxr_delete(soxr_t resampler);
]]

-- ---------------------------------------------------------------------------
-- Triangular dither
local function dither_init(seed)
  local rng = ffi.new("struct { uint32_t state; }")
  rng.state = bit.band(seed, 0xFFFFFFFF)
  return rng  -- returns a cdata object that can be passed around
end

local function dither_next(rng)
	local x = rng.state
	x = bit.bxor(x, bit.lshift(x, 13))
	x = bit.bxor(x, bit.rshift(x, 17))
	x = bit.bxor(x, bit.lshift(x, 17))
	rng.state = bit.band(x, 0xFFFFFFFF)
	return tonumber(x) / 0x100000000
end

local function triangular_dither(rng)
  return (dither_next(rng) + dither_next(rng)) - 1.0
end

-- ---------------------------------------------------------------------------
-- Resample float buffer (returns new buffer, total output samples)
local function resample(input, input_len, input_rate, output_rate, channels, quality_level)
  local io_spec = ffi.new("soxr_io_spec_t", {
    io_ratio = output_rate / input_rate,
    max_io_buf = 0,
    latency = 0,
    flags = 0,
  })
  local q_spec = ffi.new("soxr_quality_spec_t", {
    precision = 0,
    passband_end = 0,
    stopband_begin = 0,
    phase_response = 0,
    flags = quality_level,
    op = 0,
  })
  local error = ffi.new("soxr_error_t[1]")
  local soxr = libsoxr.soxr_create(input_rate, output_rate, channels, error, io_spec, q_spec, nil)
  if soxr == nil then
    io.stderr:write("soxr_create failed: ", ffi.string(error[0]), "\n")
    os.exit(1)
  end

  local output_max = math.ceil(input_len * output_rate / input_rate) + 1024
  local output = ffi.new("float[?]", output_max * channels)
  local total_out = 0
  local consumed = ffi.new("size_t[1]")
  local generated = ffi.new("size_t[1]")
  local offset = 0

  while offset < input_len do
    local in_ptr = input + offset * channels
    local in_len = input_len - offset
    local ret = libsoxr.soxr_process(soxr, in_ptr, in_len, consumed,
                                      output + total_out * channels,
                                      output_max - total_out,
                                      generated)
    if ret ~= nil then
      io.stderr:write("soxr_process error: ", ffi.string(ret), "\n")
      libsoxr.soxr_delete(soxr)
      os.exit(1)
    end
    total_out = total_out + generated[0]
    offset = offset + consumed[0]
  end
  libsoxr.soxr_delete(soxr)
  return output, total_out
end

-- ---------------------------------------------------------------------------
-- float -> int16 with dither
local function float_to_s16(input, nsamples, channels, dither_state, if_apply_dither)
  local out = ffi.new("int16_t[?]", nsamples * channels)
  for i = 0, nsamples * channels - 1 do
    local dith = if_apply_dither and (triangular_dither(dither_state) * (1.0/32767.0)) or 0.0
    local val = input[i] + dith
    if val < -1.0 then val = -1.0 end
    if val > 1.0 then val = 1.0 end
    out[i] = math.floor(val * 32767 + 0.5)
  end
  return out
end


-- ---------------------------------------------------------------------------
-- Gain measurement pass
local function measure_gain(float_buf, total_samples, channels,
                            input_rate, target_rate, opposite_rate,
                            main_quality, if_apply_dither)
  local copy_size = total_samples * channels
  local copy = ffi.new("float[?]", copy_size)
  ffi.copy(copy, float_buf, copy_size * ffi.sizeof("float"))

  if target_rate <= 0 or input_rate <= 0 or opposite_rate <= 0 then
    io.stderr:write("Invalid sample rate\n")
    os.exit(1)
  end

  -- 1. resample to target rate
  local res1, res1_samples
  if input_rate == target_rate then
    res1, res1_samples = copy, total_samples
  else
    res1, res1_samples = resample(copy, total_samples, input_rate, target_rate, channels, main_quality)
  end

  -- 2. int16 with dither (seed 12345)
  local dither_state = dither_init(12345)
	local int16_1 = float_to_s16(res1, res1_samples, channels, dither_state, if_apply_dither)

  -- 3. back to float, resample to opposite rate (medium)
  local float2 = ffi.new("float[?]", res1_samples * channels)
  for i = 0, res1_samples * channels - 1 do
    float2[i] = int16_1[i] / 32767.0
  end
  local res2, res2_samples = resample(float2, res1_samples, target_rate, opposite_rate, channels, 2)  -- 2 = SOXR_MQ

  -- 4. int16 again (no dither)
  local int16_2 = ffi.new("int16_t[?]", res2_samples * channels)
  for i = 0, res2_samples * channels - 1 do
    local v = res2[i]
    if v < -1.0 then v = -1.0 end
    if v > 1.0 then v = 1.0 end
    int16_2[i] = math.floor(v * 32767 + 0.5)
  end

  -- 5. peak
  local max_abs = 0
  for i = 0, res2_samples * channels - 1 do
    local v = math.abs(int16_2[i])
    -- Peak measurement sanity: values outside [-32768, 32767] indicate a bug.
    if v > 32768 then
      io.stderr:write("Internal error: post-resample peak out of range\n")
      os.exit(1)
    end
    if v > max_abs then max_abs = v end
  end

  -- 6. attenuation
  local peak_lin = max_abs / 32767.0
  local atten_db = 0.0
  if peak_lin > 1.0 then
    atten_db = 20.0 * math.log10(peak_lin)
  end
  -- round up to next 0.1 dB
  atten_db = math.ceil(atten_db * 10.0) / 10.0
  return atten_db
end

-- ---------------------------------------------------------------------------
-- Final output pass
local function output_pass(float_buf, total_samples, channels,
                           input_rate, target_rate, gain_db, main_quality, if_apply_dither)
  -- apply gain
  local linear = 10.0 ^ (-gain_db / 20.0)
  if linear ~= linear then  -- NaN check
    io.stderr:write("Invalid gain value\n")
    os.exit(1)
  end
  local copy_size = total_samples * channels
  local copy = ffi.new("float[?]", copy_size)
  ffi.copy(copy, float_buf, copy_size * ffi.sizeof("float"))
  for i = 0, copy_size - 1 do copy[i] = copy[i] * linear end

  local res, res_samples
  if input_rate == target_rate then
    res, res_samples = copy, total_samples
  else
    res, res_samples = resample(copy, total_samples, input_rate, target_rate, channels, main_quality)
  end

  local dither_state = dither_init(12345)
  local int16 = float_to_s16(res, res_samples, channels, dither_state, if_apply_dither)

  -- WAV header
  local bps = 2
  local data_size = res_samples * channels * bps
  local header = ffi.new("unsigned char[44]")
  header[0]=0x52; header[1]=0x49; header[2]=0x46; header[3]=0x46   -- "RIFF"
  local file_size = 36 + data_size
  ffi.copy(header+4, ffi.new("uint32_t[1]", file_size), 4)
  header[8]=0x57; header[9]=0x41; header[10]=0x56; header[11]=0x45  -- "WAVE"
  header[12]=0x66; header[13]=0x6D; header[14]=0x74; header[15]=0x20 -- "fmt "
  ffi.copy(header+16, ffi.new("uint32_t[1]", 16), 4)
  ffi.copy(header+20, ffi.new("uint16_t[1]", 1), 2)   -- PCM
  ffi.copy(header+22, ffi.new("uint16_t[1]", channels), 2)
  ffi.copy(header+24, ffi.new("uint32_t[1]", target_rate), 4)
  local byte_rate = target_rate * channels * bps
  ffi.copy(header+28, ffi.new("uint32_t[1]", byte_rate), 4)
  local block_align = channels * bps
  ffi.copy(header+32, ffi.new("uint16_t[1]", block_align), 2)
  ffi.copy(header+34, ffi.new("uint16_t[1]", 16), 2)
  header[36]=0x64; header[37]=0x61; header[38]=0x74; header[39]=0x61 -- "data"
  ffi.copy(header+40, ffi.new("uint32_t[1]", data_size), 4)

  io.stdout:write(ffi.string(header, 44))
  io.stdout:write(ffi.string(int16, data_size))
end

-- ---------------------------------------------------------------------------
-- Main
local function main()
  local target_rate = parse_args()

  -- Detect input type
  local input_type, input_arg1, input_arg2 = get_input()

  -- Probe
  local sample_rate, sample_fmt_name, sample_fmt, codec_name = probe_input(input_type, input_arg1, input_arg2)
  if sample_rate < 1000 then
    io.stderr:write("Invalid sample rate\n")
    os.exit(1)
  end
  local if_apply_dither = if_sampl_gt_16bit(sample_fmt)

  local opposite_rate = (target_rate == 44100) and 48000 or 44100
  local main_quality = 3     -- SOXR_HQ

  -- Decode
  local float_buf, total_samples, channels = decode_audio(input_type, input_arg1, input_arg2)
  if not float_buf or total_samples == 0 then
    io.stderr:write("Decoding failed or no audio\n")
    os.exit(1)
  end
  if channels <= 0 or channels > 256 then
    io.stderr:write("Invalid channel count: ", tostring(channels), "\n")
    os.exit(1)
  end

  -- Override the dither flag if the actual bit depth is ≤16
  -- (e.g. the input was upsampled from a lower bit‑depth source)
  if if_apply_dither then
    if_apply_dither = detect_effective_bits(float_buf, total_samples, channels, sample_fmt)
  end


  -- Measure gain
  local gain_db = measure_gain(float_buf, total_samples, channels,
                               sample_rate, target_rate, opposite_rate,
                               main_quality, if_apply_dither)

  -- Summary to stderr (only if terminal)
  if ffi.C.isatty(2) then
    local parts = {}
    if sample_rate ~= target_rate then
      table.insert(parts, string.format("%dHz -> %dHz", sample_rate, target_rate))
    end

    -- input format, if different from output
    local is_input_s16 = (sample_fmt == AV_SAMPLE_FMT_S16 or
                          sample_fmt == AV_SAMPLE_FMT_S16P)
    if not is_input_s16 then
      local input_gt_16 = if_sampl_gt_16bit(sample_fmt)
      if input_gt_16 and not if_apply_dither then
        -- container >16bit but actual content is ≤16 (upsampled)
        -- We know the effective depth is at most 16; assume 16.
        table.insert(parts, sample_fmt_name .. " (upsampled)")
      elseif input_gt_16 and if_apply_dither then
        -- genuine >16bit audio, dither is active
        table.insert(parts, sample_fmt_name .. " dither")
      else
        -- input depth ≤16 but not s16 (e.g. u8)
        table.insert(parts, sample_fmt_name)
      end
    end
    -- output format (always 16‑bit)
    table.insert(parts, "s16")

    if gain_db > 0 then
      table.insert(parts, string.format("gain -%.1fdB", gain_db))
    end
    if #parts > 0 then
      io.stderr:write("afiresamp: ", table.concat(parts, ", "), "\n")
    end
  end

  -- Final output
  output_pass(float_buf, total_samples, channels, sample_rate, target_rate, gain_db, main_quality, if_apply_dither)

  -- Cleanup
  if input_type == "pipe" then
    C.munmap(input_arg1, input_arg2)
  end
end

main()
