-- Pure-Lua cryptographic helpers needed for the WebSocket handshake.
-- SHA-1 (RFC 3174) implemented with LuaJIT's bit library, plus base64.

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol = bit.lshift, bit.rshift, bit.rol

local M = {}

--- SHA-1 digest of a string, returned as a 20-byte raw binary string.
---@param msg string
---@return string raw 20-byte digest
function M.sha1_raw(msg)
  local h0 = 0x67452301
  local h1 = 0xEFCDAB89
  local h2 = 0x98BADCFE
  local h3 = 0x10325476
  local h4 = 0xC3D2E1F0

  local msg_len = #msg
  local bit_len = msg_len * 8

  -- Pre-processing: append 0x80, then 0x00 until length % 64 == 56,
  -- then the 64-bit big-endian message length.
  msg = msg .. "\128"
  while (#msg % 64) ~= 56 do
    msg = msg .. "\0"
  end
  -- 64-bit length. Lua numbers are doubles; message length here is small
  -- enough that the high 32 bits are effectively 0 for our payloads.
  local hi = math.floor(bit_len / 0x100000000)
  local lo = bit_len % 0x100000000
  local function u32_be(n)
    return string.char(
      band(rshift(n, 24), 0xFF),
      band(rshift(n, 16), 0xFF),
      band(rshift(n, 8), 0xFF),
      band(n, 0xFF)
    )
  end
  msg = msg .. u32_be(hi) .. u32_be(lo)

  for chunk = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      local off = chunk + i * 4
      local b1, b2, b3, b4 = msg:byte(off, off + 3)
      w[i] = bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
    end
    for i = 16, 79 do
      w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = bor(band(b, c), band(bnot(b), d))
        k = 0x5A827999
      elseif i < 40 then
        f = bxor(b, c, d)
        k = 0x6ED9EBA1
      elseif i < 60 then
        f = bor(band(b, c), band(b, d), band(c, d))
        k = 0x8F1BBCDC
      else
        f = bxor(b, c, d)
        k = 0xCA62C1D6
      end
      -- Use tobit-style truncation via normalize through bit ops.
      local temp = (rol(a, 5) + f + e + k + w[i])
      -- Force into 32-bit range.
      temp = bor(temp, 0)
      e = d
      d = c
      c = rol(b, 30)
      b = a
      a = temp
    end

    h0 = bor(h0 + a, 0)
    h1 = bor(h1 + b, 0)
    h2 = bor(h2 + c, 0)
    h3 = bor(h3 + d, 0)
    h4 = bor(h4 + e, 0)
  end

  local function to_be_bytes(n)
    return string.char(
      band(rshift(n, 24), 0xFF),
      band(rshift(n, 16), 0xFF),
      band(rshift(n, 8), 0xFF),
      band(n, 0xFF)
    )
  end

  return to_be_bytes(h0) .. to_be_bytes(h1) .. to_be_bytes(h2) .. to_be_bytes(h3) .. to_be_bytes(h4)
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Base64-encode a (binary) string. Prefers Neovim's builtin when available.
---@param data string
---@return string
function M.base64_encode(data)
  if vim.base64 and vim.base64.encode then
    return vim.base64.encode(data)
  end
  local out = {}
  local len = #data
  local i = 1
  while i <= len do
    local b1 = data:byte(i)
    local b2 = data:byte(i + 1)
    local b3 = data:byte(i + 2)
    local n = lshift(b1, 16) + lshift(b2 or 0, 8) + (b3 or 0)
    local c1 = rshift(n, 18) % 64
    local c2 = rshift(n, 12) % 64
    local c3 = rshift(n, 6) % 64
    local c4 = n % 64
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1)
    out[#out + 1] = B64:sub(c2 + 1, c2 + 1)
    out[#out + 1] = b2 and B64:sub(c3 + 1, c3 + 1) or "="
    out[#out + 1] = b3 and B64:sub(c4 + 1, c4 + 1) or "="
    i = i + 3
  end
  return table.concat(out)
end

--- Compute the Sec-WebSocket-Accept value for a given client key.
---@param key string Sec-WebSocket-Key header value
---@return string
function M.websocket_accept(key)
  local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  return M.base64_encode(M.sha1_raw(key .. GUID))
end

return M
