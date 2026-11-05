-- Inflate/Deflate for headless PoB.
--
-- In the GUI these come from SimpleGraphic. HeadlessWrapper has none, so PoB's own
-- definitions are the empty stubs in _SimpleGraphic.def.lua (or missing entirely).
-- Every timeless jewel lookup table (Lethal Pride, Glorious Vanity, ...) is zlib
-- data read through Inflate, so without this module timeless jewels silently do
-- nothing: the build loads, the jewel is socketed, and its conquered passives are
-- vanilla. Measured on a 3.29 strength stacker: -303 Strength and -16% DPS.
--
-- Binds the zlib shipped in PoB's runtime/ (zlib1.dll on Windows) through LuaJIT FFI,
-- falling back to the system zlib elsewhere. Returns nil when no zlib can be loaded.
local ok, ffi = pcall(require, 'ffi')
if not ok then return nil end

pcall(ffi.cdef, [[
typedef struct pobmcp_z_stream {
  const unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
  unsigned char *next_out; unsigned int avail_out; unsigned long total_out;
  const char *msg; void *state; void *zalloc; void *zfree; void *opaque;
  int data_type; unsigned long adler; unsigned long reserved;
} pobmcp_z_stream;
const char *zlibVersion(void);
int inflateInit2_(pobmcp_z_stream *s, int windowBits, const char *version, int stream_size);
int inflate(pobmcp_z_stream *s, int flush);
int inflateEnd(pobmcp_z_stream *s);
int deflateInit2_(pobmcp_z_stream *s, int level, int method, int windowBits, int memLevel, int strategy, const char *version, int stream_size);
int deflate(pobmcp_z_stream *s, int flush);
int deflateEnd(pobmcp_z_stream *s);
]])

local z
for _, name in ipairs({ 'zlib1', 'z', 'libz.so.1', 'libz.1.dylib' }) do
  local loaded, lib = pcall(ffi.load, name)
  if loaded then
    -- Some PoB runtimes ship a z.dll that is not zlib; insist on the symbol.
    if pcall(function() return lib.zlibVersion end) then z = lib; break end
  end
end
if not z then return nil end

local Z_OK, Z_STREAM_END, Z_BUF_ERROR, Z_FINISH = 0, 1, -5, 4
local CHUNK = 1048576
local STREAM_SIZE = ffi.sizeof('pobmcp_z_stream')

local function pump(step, s, flush)
  local out, buf = {}, ffi.new('unsigned char[?]', CHUNK)
  while true do
    s.next_out, s.avail_out = buf, CHUNK
    local rc = step(s, flush)
    out[#out + 1] = ffi.string(buf, CHUNK - s.avail_out)
    if rc == Z_STREAM_END then return table.concat(out) end
    if rc ~= Z_OK and rc ~= Z_BUF_ERROR then
      return nil, 'zlib error ' .. rc .. (s.msg ~= nil and (': ' .. ffi.string(s.msg)) or '')
    end
    if rc == Z_BUF_ERROR and s.avail_in == 0 and s.avail_out ~= 0 then
      return nil, 'truncated zlib stream'
    end
  end
end

local M = {}

-- Same contract as SimpleGraphic: zlib or gzip header, detected automatically.
function M.Inflate(data)
  if type(data) ~= 'string' or #data == 0 then return nil, 'no data' end
  local s = ffi.new('pobmcp_z_stream')
  if z.inflateInit2_(s, 15 + 32, z.zlibVersion(), STREAM_SIZE) ~= Z_OK then return nil, 'inflateInit failed' end
  s.next_in, s.avail_in = data, #data
  local res, err = pump(z.inflate, s, 0)
  z.inflateEnd(s)
  return res, err
end

function M.Deflate(data, isGzip)
  if type(data) ~= 'string' then return nil, 'no data' end
  local s = ffi.new('pobmcp_z_stream')
  if z.deflateInit2_(s, 9, 8, isGzip and 31 or 15, 8, 0, z.zlibVersion(), STREAM_SIZE) ~= Z_OK then
    return nil, 'deflateInit failed'
  end
  s.next_in, s.avail_in = data, #data
  local res, err = pump(z.deflate, s, Z_FINISH)
  z.deflateEnd(s)
  return res, err
end

-- True when an Inflate global is missing or does not actually decompress
-- (the headless stub returns "").
function M.isStubInflate(fn)
  if type(fn) ~= 'function' then return true end
  local probe = M.Deflate('pob-mcp inflate probe')
  local okCall, res = pcall(fn, probe)
  return not okCall or res ~= 'pob-mcp inflate probe'
end

return M
