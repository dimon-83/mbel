// SPDX-License-Identifier: Apache-2.0
// mbel builtin library — base64 codec + UTF-8 helpers.
// Matches expr's toBase64/fromBase64 (standard alphabet, padded).

///|
/// UTF-8 encodes a string.
pub fn utf8_encode(s : String) -> Bytes {
  let buf : Array[Byte] = []
  for c in s {
    let cp = c.to_int()
    if cp < 0x80 {
      buf.push(cp.to_byte())
    } else if cp < 0x800 {
      buf.push((0xC0 | (cp >> 6)).to_byte())
      buf.push((0x80 | (cp & 0x3F)).to_byte())
    } else if cp < 0x10000 {
      buf.push((0xE0 | (cp >> 12)).to_byte())
      buf.push((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      buf.push((0x80 | (cp & 0x3F)).to_byte())
    } else {
      buf.push((0xF0 | (cp >> 18)).to_byte())
      buf.push((0x80 | ((cp >> 12) & 0x3F)).to_byte())
      buf.push((0x80 | ((cp >> 6) & 0x3F)).to_byte())
      buf.push((0x80 | (cp & 0x3F)).to_byte())
    }
  }
  Bytes::from_array(buf)
}

///|
/// Decodes UTF-8 bytes; invalid sequences become U+FFFD (like Go).
pub fn utf8_decode(b : Bytes) -> String {
  let chars : Array[Char] = []
  let n = b.length()
  let mut i = 0
  while i < n {
    let b0 = b[i].to_int()
    let cp : Int = if b0 < 0x80 {
      b0
    } else if b0 >= 0xC0 && b0 < 0xE0 && i + 1 < n {
      ((b0 & 0x1F) << 6) | (b[i + 1].to_int() & 0x3F)
    } else if b0 >= 0xE0 && b0 < 0xF0 && i + 2 < n {
      ((b0 & 0x0F) << 12) |
      ((b[i + 1].to_int() & 0x3F) << 6) |
      (b[i + 2].to_int() & 0x3F)
    } else if b0 >= 0xF0 && b0 < 0xF8 && i + 3 < n {
      ((b0 & 0x07) << 18) |
      ((b[i + 1].to_int() & 0x3F) << 12) |
      ((b[i + 2].to_int() & 0x3F) << 6) |
      (b[i + 3].to_int() & 0x3F)
    } else {
      0xFFFD
    }
    let width : Int = if b0 < 0x80 {
      1
    } else if b0 >= 0xC0 && b0 < 0xE0 {
      2
    } else if b0 >= 0xE0 && b0 < 0xF0 {
      3
    } else if b0 >= 0xF0 && b0 < 0xF8 {
      4
    } else {
      1
    }
    chars.push(Char::from_int(cp))
    i += width
  }
  String::from_array(chars)
}

///|
const Alphabet64 : String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

///|
/// Standard base64 encode (padded).
pub fn encode64(s : String) -> String {
  let data = utf8_encode(s)
  let n = data.length()
  let out = StringBuilder::new()
  let alpha = Alphabet64.to_array()
  let mut i = 0
  while i + 3 <= n {
    let v = (data[i].to_int() << 16) |
      (data[i + 1].to_int() << 8) |
      data[i + 2].to_int()
    out.write_char(alpha[(v >> 18) & 63])
    out.write_char(alpha[(v >> 12) & 63])
    out.write_char(alpha[(v >> 6) & 63])
    out.write_char(alpha[v & 63])
    i += 3
  }
  let rem = n - i
  if rem == 1 {
    let v = data[i].to_int() << 16
    out.write_char(alpha[(v >> 18) & 63])
    out.write_char(alpha[(v >> 12) & 63])
    out.write_string("==")
  } else if rem == 2 {
    let v = (data[i].to_int() << 16) | (data[i + 1].to_int() << 8)
    out.write_char(alpha[(v >> 18) & 63])
    out.write_char(alpha[(v >> 12) & 63])
    out.write_char(alpha[(v >> 6) & 63])
    out.write_string("=")
  }
  out.to_string()
}

///|
/// Standard base64 decode. Invalid input raises EvalError.
pub fn decode64(s : String) -> String raise @evaluator.EvalError {
  let chars = s.to_array()
  let n = chars.length()
  if n % 4 != 0 {
    raise @evaluator.EvalErr("illegal base64 data")
  }
  let buf : Array[Byte] = []
  let mut i = 0
  while i < n {
    let mut v = 0
    let mut pad = 0
    for j in 0..<4 {
      let c = chars[i + j]
      if c == '=' {
        pad += 1
        v = v << 6
      } else {
        if pad > 0 {
          raise @evaluator.EvalErr("illegal base64 data")
        }
        let idx = alpha_index(c)
        if idx < 0 {
          raise @evaluator.EvalErr("illegal base64 data")
        }
        v = (v << 6) | idx
      }
    }
    buf.push(((v >> 16) & 0xFF).to_byte())
    if pad < 2 {
      buf.push(((v >> 8) & 0xFF).to_byte())
    }
    if pad < 1 {
      buf.push((v & 0xFF).to_byte())
    }
    i += 4
  }
  utf8_decode(Bytes::from_array(buf))
}

///|
fn alpha_index(c : Char) -> Int {
  if c >= 'A' && c <= 'Z' {
    return c.to_int() - 'A'.to_int()
  }
  if c >= 'a' && c <= 'z' {
    return c.to_int() - 'a'.to_int() + 26
  }
  if c >= '0' && c <= '9' {
    return c.to_int() - '0'.to_int() + 52
  }
  if c == '+' {
    return 62
  }
  if c == '/' {
    return 63
  }
  -1
}
