-- Minimal RFC 6455 WebSocket frame encode/decode.

local bit = require("bit")
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local lshift, rshift = bit.lshift, bit.rshift

local M = {}

M.OPCODE = {
  CONTINUATION = 0x0,
  TEXT = 0x1,
  BINARY = 0x2,
  CLOSE = 0x8,
  PING = 0x9,
  PONG = 0xA,
}

--- Try to decode a single frame from the front of `buf`.
--- Returns frame, rest. If there is not enough data yet, returns nil, buf.
---@param buf string
---@return table|nil frame { fin, opcode, payload }
---@return string rest
function M.decode(buf)
  if #buf < 2 then
    return nil, buf
  end
  local b1 = buf:byte(1)
  local b2 = buf:byte(2)
  local fin = band(b1, 0x80) ~= 0
  local opcode = band(b1, 0x0F)
  local masked = band(b2, 0x80) ~= 0
  local len = band(b2, 0x7F)
  local offset = 2

  if len == 126 then
    if #buf < offset + 2 then
      return nil, buf
    end
    len = bor(lshift(buf:byte(offset + 1), 8), buf:byte(offset + 2))
    offset = offset + 2
  elseif len == 127 then
    if #buf < offset + 8 then
      return nil, buf
    end
    -- 64-bit length; only use the low 32 bits (payloads are small).
    len = 0
    for i = 1, 8 do
      len = len * 256 + buf:byte(offset + i)
    end
    offset = offset + 8
  end

  local mask_key
  if masked then
    if #buf < offset + 4 then
      return nil, buf
    end
    mask_key = { buf:byte(offset + 1, offset + 4) }
    offset = offset + 4
  end

  if #buf < offset + len then
    return nil, buf
  end

  local payload = buf:sub(offset + 1, offset + len)
  if masked and len > 0 then
    -- Unmask in chunks to avoid overflowing string.char/unpack on big payloads.
    local out = {}
    local pos = 1
    local CHUNK = 4096
    while pos <= len do
      local stop = math.min(pos + CHUNK - 1, len)
      local bytes = { payload:byte(pos, stop) }
      for i = 1, #bytes do
        local idx = pos + i - 1
        bytes[i] = bxor(bytes[i], mask_key[((idx - 1) % 4) + 1])
      end
      out[#out + 1] = string.char(unpack(bytes))
      pos = stop + 1
    end
    payload = table.concat(out)
  end

  local rest = buf:sub(offset + len + 1)
  return { fin = fin, opcode = opcode, payload = payload }, rest
end

--- Encode an (unmasked) server frame.
---@param opcode integer
---@param payload string
---@return string
function M.encode(opcode, payload)
  payload = payload or ""
  local len = #payload
  local header
  if len < 126 then
    header = string.char(bor(0x80, opcode), len)
  elseif len < 0x10000 then
    header = string.char(bor(0x80, opcode), 126, band(rshift(len, 8), 0xFF), band(len, 0xFF))
  else
    local bytes = { bor(0x80, opcode), 127 }
    for i = 7, 0, -1 do
      bytes[#bytes + 1] = band(rshift(len, i * 8), 0xFF)
    end
    header = string.char(unpack(bytes))
  end
  return header .. payload
end

function M.text(payload)
  return M.encode(M.OPCODE.TEXT, payload)
end

function M.pong(payload)
  return M.encode(M.OPCODE.PONG, payload)
end

function M.close(payload)
  return M.encode(M.OPCODE.CLOSE, payload or "")
end

return M
