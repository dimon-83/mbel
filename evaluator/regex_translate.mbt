// SPDX-License-Identifier: Apache-2.0
// RE2 → MoonBit core regex translation for the `matches` operator.
//
// The core engine (`moonbitlang/core/string` `Regex`) implements a regex
// dialect close to Go's RE2, but it is not RE2: it has no `\d`/`\w`/`\s`
// class escapes (POSIX classes instead), its `.` matches newline, it
// rejects a leading/trailing `-` in a character class, and it only
// accepts the `(?i:…)` form of inline flags.
//
// This module rewrites the RE2 constructs that do have a core
// equivalent, and raises a named, actionable error for the ones that do
// not. The documented cuts are:
//
//   - `\p{…}` / `\P{…}` Unicode property classes
//   - `(?m)` multiline mode
//   - `\D` / `\W` / `\S` *inside* a character class (e.g. `[\D5]`), which
//     needs character-class set algebra
//   - `(?U)` (ungreedy mode)
//   - switching case-insensitivity back off with `(?-i)` when it is on
//
// Translation runs at most once per distinct pattern per engine: the
// caller caches the compiled result, and failures are cached too.

///|
/// Inline flags in effect at one point in the pattern (RE2 `(?flags)`).
/// `m` and `U` are not representable here — they are rejected at parse
/// time rather than silently dropped.
priv struct ReFlags {
  case_insensitive : Bool
  dot_all : Bool
}

///|
/// An RE2 construct the core engine cannot express.
fn re_cut(what : String, hint : String) -> EvalError {
  EvalError::EvalErr("unsupported regex construct " + what + ": " + hint)
}

///|
/// Parses an inline-flag spec at `start`: `[imsU]*` optionally followed
/// by `-` and more of those letters. Returns the enabled letters, the
/// disabled letters, the index just past the spec, and whether the spec
/// was terminated by `:` (group form) rather than `)` (bare form).
fn re_parse_flags(
  src : Array[Char],
  start : Int,
) -> (String, String, Int, Bool) raise EvalError {
  let on = StringBuilder::new()
  let off = StringBuilder::new()
  let mut minus = false
  let mut i = start
  while i < src.length() {
    let c = src[i]
    if c == ':' {
      return (on.to_string(), off.to_string(), i + 1, true)
    }
    if c == ')' {
      return (on.to_string(), off.to_string(), i, false)
    }
    if c == '-' {
      if minus {
        raise re_cut("(?-…-…)", "at most one '-' is allowed in a flag group")
      }
      minus = true
      i = i + 1
      continue
    }
    match c {
      'i' | 's' | 'm' | 'U' => {
        if minus {
          off.write_char(c)
        } else {
          on.write_char(c)
        }
        i = i + 1
      }
      _ =>
        raise EvalError::EvalErr(
          "invalid regex: unknown inline flag '" + c.to_string() + "'",
        )
    }
  }
  raise EvalError::EvalErr("invalid regex: unterminated (?…) flag group")
}

///|
/// Applies a parsed flag spec to the flags in effect. `m` and `U` have
/// no core equivalent and are rejected here; whether `-i` is expressible
/// depends on the wrapper context, so that is decided by the caller.
fn re_apply_flags(
  on : String,
  off : String,
  cur_i : Bool,
  cur_s : Bool,
) -> (Bool, Bool) raise EvalError {
  let mut i = cur_i
  let mut s = cur_s
  for c in on {
    match c {
      'i' => i = true
      's' => s = true
      'm' =>
        raise re_cut(
          "(?m)",
          "multiline mode is not supported (use explicit anchors)",
        )
      _ => raise re_cut("(?U)", "ungreedy mode is not supported")
    }
  }
  for c in off {
    match c {
      's' => s = false
      'm' => () // core is already non-multiline: (?-m) is a no-op
      'i' => i = false
      _ => raise re_cut("(?U)", "ungreedy mode is not supported")
    }
  }
  (i, s)
}

///|
/// Translates an escape sequence in the pattern body (outside a
/// character class), writing the core equivalent to `out`. Returns the
/// index just past the escape.
fn re_translate_escape(
  src : Array[Char],
  start : Int,
  out : StringBuilder,
) -> Int raise EvalError {
  if start + 1 >= src.length() {
    out.write_char('\\')
    return start + 1
  }
  let c = src[start + 1]
  match c {
    'd' => out.write_string("[[:digit:]]")
    'D' => out.write_string("[^[:digit:]]")
    'w' => out.write_string("[[:word:]]")
    'W' => out.write_string("[^[:word:]]")
    // Go's `\s` is [\t\n\f\r ] and deliberately excludes \v, while core's
    // [[:space:]] includes it — so the set is written out explicitly.
    's' => out.write_string("[\\t\\n\\f\\r ]")
    'S' => out.write_string("[^\\t\\n\\f\\r ]")
    'p' | 'P' => return re_translate_unicode_class(src, start, out, c == 'P')
    'Q' => {
      // \Q…\E: the enclosed text is literal. Escape it for core, which has
      // no quoting escape. A missing \E quotes to the end of the pattern
      // (as in RE2).
      let n = src.length()
      let mut i = start + 2
      while i < n {
        if src[i] == '\\' && i + 1 < n && src[i + 1] == 'E' {
          return i + 2
        }
        if is_regex_metachar(src[i]) {
          out.write_char('\\')
        }
        out.write_char(src[i])
        i = i + 1
      }
      return i
    }
    'E' => raise EvalError::EvalErr("invalid regex: \\E without a matching \\Q")
    'A' => out.write_char('^')
    'z' => out.write_char('$')
    'x' => return re_translate_hex_escape(src, start, out)
    _ => {
      out.write_char('\\')
      out.write_char(c)
    }
  }
  start + 2
}

///|
/// True for the characters that must be escaped to be literal.
fn is_regex_metachar(c : Char) -> Bool {
  match c {
    '.' | '^' | '$' | '*' | '+' | '?' | '(' | ')' | '[' | ']' | '{' | '}' | '|' | '\\' =>
      true
    _ => false
  }
}

///|
/// `\xHH` and `\x{H…}` are code-point escapes in RE2; core spells those
/// `\u00HH` and `\u{H…}`. Returns the index just past the escape.
fn re_translate_hex_escape(
  src : Array[Char],
  start : Int,
  out : StringBuilder,
) -> Int raise EvalError {
  let n = src.length()
  let i = start + 2
  if i < n && src[i] == '{' {
    let mut j = i + 1
    while j < n && src[j] != '}' {
      j = j + 1
    }
    if j >= n {
      raise EvalError::EvalErr("invalid regex: unterminated \\x{…} escape")
    }
    // \x{H…} -> \u{H…}
    out.write_string("\\u")
    for k in i..<(j + 1) {
      out.write_char(src[k])
    }
    return j + 1
  }
  if i + 1 >= n || !is_hex(src[i]) || !is_hex(src[i + 1]) {
    raise EvalError::EvalErr("invalid regex: \\x needs two hex digits")
  }
  out.write_string("\\u00")
  out.write_char(src[i])
  out.write_char(src[i + 1])
  i + 2
}

///|
/// Uppercase hex, for the `\u{H…}` ranges a class expansion is built from.
fn hex_upper(v : Int) -> String {
  let digits : Array[Char] = [
    '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F',
  ]
  if v == 0 {
    return "0"
  }
  let buf : Array[Char] = []
  let mut x = v
  while x > 0 {
    buf.push(digits[x % 16])
    x = x / 16
  }
  let out = StringBuilder::new()
  for i in 0..<buf.length() {
    out.write_char(buf[buf.length() - 1 - i])
  }
  out.to_string()
}

///|
/// Reads the class name of a `\p{Name}` / `\pN` escape, returning it with
/// the index just past the escape.
fn re_unicode_class_name(
  src : Array[Char],
  start : Int,
) -> (String, Int) raise EvalError {
  let n = src.length()
  let i = start + 2
  if i < n && src[i] == '{' {
    let mut j = i + 1
    while j < n && src[j] != '}' {
      j = j + 1
    }
    if j >= n {
      raise EvalError::EvalErr("invalid regex: unterminated \\p{…} escape")
    }
    let buf = StringBuilder::new()
    for k in (i + 1)..<j {
      buf.write_char(src[k])
    }
    (buf.to_string(), j + 1)
  } else if i < n {
    (src[i].to_string(), i + 1)
  } else {
    raise EvalError::EvalErr("invalid regex: \\p needs a class name")
  }
}

///|
/// Writes the ranges of a `\p{…}` name to `out`.
fn re_write_unicode_ranges(out : StringBuilder, name : String) -> Unit raise EvalError {
  let rs = match unicode_class(name) {
    Some(r) => r
    None =>
      raise EvalError::EvalErr("invalid regex: unknown Unicode class " + name)
  }
  for r in rs {
    let (lo, hi) = r
    out.write_string("\\u{" + hex_upper(lo) + "}")
    if hi > lo {
      out.write_string("-\\u{" + hex_upper(hi) + "}")
    }
  }
}

///|
/// `\p{L}`, `\pL`, `\P{Greek}` — expand a Unicode class into a core
/// character class. Go's own range tables back this (see
/// evaluator/unicode_classes.mbt), so `\p{…}` matches expr exactly.
fn re_translate_unicode_class(
  src : Array[Char],
  start : Int,
  out : StringBuilder,
  negated : Bool,
) -> Int raise EvalError {
  let (name, next) = re_unicode_class_name(src, start)
  out.write_char('[')
  if negated {
    out.write_char('^')
  }
  re_write_unicode_ranges(out, name)
  out.write_char(']')
  next
}

///|
/// The same expansion inside a character class, where the ranges are
/// written inline (nested brackets are not valid). `\P{…}` there needs
/// class set algebra, so it stays a cut — like `\D`/`\W`/`\S`.
fn re_translate_unicode_class_inline(
  src : Array[Char],
  start : Int,
  out : StringBuilder,
) -> Int raise EvalError {
  let (name, next) = re_unicode_class_name(src, start)
  re_write_unicode_ranges(out, name)
  next
}

///|
fn is_hex(c : Char) -> Bool {
  match c {
    '0'..='9' | 'a'..='f' | 'A'..='F' => true
    _ => false
  }
}

///|
/// Translates an escape sequence inside a character class, writing the
/// class-body fragment to `out`. The negated shorthands (`\D`, `\W`,
/// `\S`) cannot be expressed as a fragment of an enclosing class, so
/// they are rejected.
fn re_translate_class_escape(
  src : Array[Char],
  start : Int,
  out : StringBuilder,
) -> Int raise EvalError {
  if start + 1 >= src.length() {
    out.write_char('\\')
    return start + 1
  }
  let c = src[start + 1]
  match c {
    'd' => out.write_string("[:digit:]")
    'w' => out.write_string("[:word:]")
    's' => out.write_string("\\t\\n\\f\\r ")
    'D' =>
      raise re_cut(
        "\\D inside a character class",
        "write the negation as [^[:digit:]] or list the set explicitly",
      )
    'W' =>
      raise re_cut(
        "\\W inside a character class",
        "write the negation as [^[:word:]] or list the set explicitly",
      )
    'S' =>
      raise re_cut(
        "\\S inside a character class",
        "write the negation as [^\\t\\n\\f\\r ] or list the set explicitly",
      )
    'p' => return re_translate_unicode_class_inline(src, start, out)
    'P' =>
      raise re_cut(
        "\\P{…} inside a character class",
        "write the class complement instead ([^…])",
      )
    'Q' | 'E' =>
      raise re_cut(
        "\\Q…\\E inside a character class",
        "escape the literal characters instead",
      )
    // RE2 rejects these inside a class (they are anchors, word boundaries
    // or backreferences there, none of which is a class member); core would
    // otherwise read them as the literal character and silently change the
    // pattern's meaning.
    'A' | 'z' | 'Z' | 'b' | 'B' | 'G' =>
      raise EvalError::EvalErr(
        "invalid regex: \\" +
        c.to_string() +
        " is not valid inside a character class",
      )
    '1'..='9' =>
      raise EvalError::EvalErr(
        "invalid regex: backreferences are not supported",
      )
    // Core accepts \uXXXX inside a class too (including as a range end).
    'x' => return re_translate_hex_escape(src, start, out)
    _ => {
      out.write_char('\\')
      out.write_char(c)
    }
  }
  start + 2
}

///|
/// Translates one character class, `src[start]` being `[`. Returns the
/// index just past the closing `]`. Core rejects a leading or trailing
/// `-` (and a leading `]`) where Go accepts them as literals, so those
/// are escaped.
fn re_translate_class(
  src : Array[Char],
  start : Int,
  out : StringBuilder,
) -> Int raise EvalError {
  out.write_char('[')
  let n = src.length()
  let mut i = start + 1
  if i < n && src[i] == '^' {
    out.write_char('^')
    i = i + 1
  }
  // A `]` or `-` in first position is a literal in RE2.
  if i < n && src[i] == ']' {
    out.write_string("\\]")
    i = i + 1
  } else if i < n && src[i] == '-' {
    out.write_string("\\-")
    i = i + 1
  }
  while i < n {
    let c = src[i]
    if c == ']' {
      out.write_char(']')
      return i + 1
    }
    if c == '\\' {
      i = re_translate_class_escape(src, i, out)
      continue
    }
    if c == '-' {
      // A dash directly before the closing bracket is a literal in RE2.
      if i + 1 < n && src[i + 1] == ']' {
        out.write_string("\\-")
      } else {
        out.write_char('-')
      }
      i = i + 1
      continue
    }
    if c == '[' && i + 1 < n && src[i + 1] == ':' {
      // POSIX class `[:name:]`. Core implements ten of the fourteen; the
      // rest are expanded here to their RE2 (ASCII) definitions.
      let mut j = i + 1
      while j < n && !(src[j] == ':' && j + 1 < n && src[j + 1] == ']') {
        j = j + 1
      }
      if j >= n {
        raise EvalError::EvalErr("invalid regex: unterminated POSIX class")
      }
      let name = {
        let buf = StringBuilder::new()
        for k in (i + 2)..<j {
          buf.write_char(src[k])
        }
        buf.to_string()
      }
      let expanded = match name {
        // RE2/regexp/syntax ASCII definitions:
        //   cntrl [\x00-\x1F\x7F], graph [!-~], print [ -~],
        //   punct [!-/:-@\[-`{-~]
        "cntrl" => "\\u{0}-\\u{1F}\\u{7F}"
        "graph" => "\\u{21}-\\u{7E}"
        "print" => "\\u{20}-\\u{7E}"
        "punct" => "\\u{21}-\\u{2F}\\u{3A}-\\u{40}\\u{5B}-\\u{60}\\u{7B}-\\u{7E}"
        _ => ""
      }
      if expanded != "" {
        out.write_string(expanded)
      } else {
        for k in i..<(j + 2) {
          out.write_char(src[k])
        }
      }
      i = j + 2
      continue
    }
    out.write_char(c)
    i = i + 1
  }
  raise EvalError::EvalErr("invalid regex: unterminated character class")
}

///|
/// Translates one group body — from `start` up to (excluding) the
/// matching `)` or the end of the pattern. Returns the translated text
/// and the index of the terminator (or `src.length()` at end of input).
///
/// A bare `(?flags)` in RE2 applies to the rest of the *enclosing* group
/// (across `|` branches), which core can only express as a `(?i:…)`
/// wrapper around that remainder — hence the wrapper bookkeeping here.
fn re_translate_seq(
  src : Array[Char],
  start : Int,
  flags : ReFlags,
) -> (String, Int) raise EvalError {
  let out = StringBuilder::new()
  let inherited_i = flags.case_insensitive
  let mut cur_i = flags.case_insensitive
  let mut cur_s = flags.dot_all
  let mut wrapper_open = false
  let n = src.length()
  let mut i = start
  while i < n {
    let c = src[i]
    if c == ')' {
      break
    }
    if c == '\\' {
      i = re_translate_escape(src, i, out)
      continue
    }
    if c == '[' {
      i = re_translate_class(src, i, out)
      continue
    }
    if c == '.' {
      // Core's `.` also matches newline; RE2's does not unless (?s).
      out.write_string(if cur_s { "." } else { "[^\\n]" })
      i = i + 1
      continue
    }
    if c == '(' {
      if i + 1 < n && src[i + 1] == '?' {
        let j = i + 2
        if j < n && src[j] == ':' {
          // (?:…) non-capturing
          out.write_string("(?:")
          let (body, pos) = re_translate_seq(src, j + 1, {
            case_insensitive: cur_i,
            dot_all: cur_s,
          })
          out.write_string(body)
          if pos >= n {
            raise EvalError::EvalErr("invalid regex: missing )")
          }
          out.write_char(')')
          i = pos + 1
          continue
        }
        // Go spells named groups both (?<name>…) and (?P<name>…); core
        // takes the first, so the P is dropped.
        let mut lt = j
        if j < n && src[j] == 'P' {
          if j + 1 < n && src[j + 1] == '<' {
            lt = j + 1
          } else {
            raise EvalError::EvalErr(
              "invalid regex: (?P must be followed by <name>",
            )
          }
        }
        if lt < n && src[lt] == '<' {
          // (?<name>…) named group
          let mut k = lt + 1
          while k < n && src[k] != '>' {
            k = k + 1
          }
          if k >= n {
            raise EvalError::EvalErr("invalid regex: unterminated group name")
          }
          out.write_string("(?<")
          for p in (lt + 1)..<(k + 1) {
            out.write_char(src[p])
          }
          let (body, pos) = re_translate_seq(src, k + 1, {
            case_insensitive: cur_i,
            dot_all: cur_s,
          })
          out.write_string(body)
          if pos >= n {
            raise EvalError::EvalErr("invalid regex: missing )")
          }
          out.write_char(')')
          i = pos + 1
          continue
        }
        let (on, off, next, colon) = re_parse_flags(src, j)
        let (ni, ns) = re_apply_flags(on, off, cur_i, cur_s)
        if colon {
          // (?flags:…) — scoped to this group only. Turning i *off* is
          // only expressible when it is off already; core has no (?-i:…).
          if !ni && cur_i {
            raise re_cut(
              "(?-i:…)",
              "turning case-insensitivity off inside an (?i) scope is not " +
              "supported (core only implements (?i:…))",
            )
          }
          // No wrapper is needed when the enclosing scope is already
          // case-insensitive.
          out.write_string(if ni && !cur_i { "(?i:" } else { "(?:" })
          let (body, pos) = re_translate_seq(src, next, {
            case_insensitive: ni,
            dot_all: ns,
          })
          out.write_string(body)
          if pos >= n {
            raise EvalError::EvalErr("invalid regex: missing )")
          }
          out.write_char(')')
          i = pos + 1
          continue
        }
        // Bare (?flags): applies to the rest of this group. Core can only
        // express that as a (?i:…) wrapper — which we open here and close
        // at the end of this group, or as soon as a (?-i) turns it back
        // off.
        let context_i = inherited_i || wrapper_open
        if ni && !context_i {
          out.write_string("(?i:")
          wrapper_open = true
        } else if !ni && wrapper_open {
          out.write_char(')')
          wrapper_open = false
        } else if !ni && inherited_i {
          // i is on because of an enclosing wrapper that this level does
          // not own, so it cannot be closed from here.
          raise re_cut(
            "(?-i)",
            "turning case-insensitivity off inside an enclosing (?i) scope " +
            "is not supported (core only implements (?i:…))",
          )
        }
        cur_i = ni
        cur_s = ns
        // `next` is the index of the `)` that terminates the flag spec —
        // it belongs to the flag syntax, so step past it.
        i = next + 1
        continue
      }
      // plain capturing group
      out.write_char('(')
      let (body, pos) = re_translate_seq(src, i + 1, {
        case_insensitive: cur_i,
        dot_all: cur_s,
      })
      out.write_string(body)
      if pos >= n {
        raise EvalError::EvalErr("invalid regex: missing )")
      }
      out.write_char(')')
      i = pos + 1
      continue
    }
    out.write_char(c)
    i = i + 1
  }
  if wrapper_open {
    out.write_char(')')
  }
  (out.to_string(), i)
}

///|
/// Translates an RE2-style pattern into the subset of regex syntax the
/// MoonBit core engine accepts. `Err` carries the reason for a documented
/// cut (see the module header); the caller folds it into the engine's
/// "invalid regex" message.
fn translate_re2_pattern(pattern : String) -> Result[String, String] {
  let src = pattern.to_array()
  let (body, pos) = re_translate_seq(src, 0, {
    case_insensitive: false,
    dot_all: false,
  }) catch {
    EvalError::EvalErr(detail) => return Err(detail)
  }
  if pos >= src.length() {
    return Ok(body)
  }
  // An unbalanced `)` — hand the rest to core unchanged so it reports it.
  let out = StringBuilder::new()
  out.write_string(body)
  for k in pos..<src.length() {
    out.write_char(src[k])
  }
  Ok(out.to_string())
}
