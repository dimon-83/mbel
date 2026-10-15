// SPDX-License-Identifier: Apache-2.0
// A small Go time-layout interpreter.
//
// expr's `date()` does not take a strftime pattern: it takes Go's reference
// layouts ("2006-01-02", time.RFC3339, …), and a caller may pass any layout
// string. mbel therefore has to interpret Go's layout elements, not just
// recognise a fixed set of ISO forms. The seven built-in layouts need year
// (2006/06), month (01/1/Jan/January), day (02/2/_2), hour (15/03/3),
// minute (04/4), second (05/5), fractional seconds, the AM/PM marker, a
// zone name (MST), the numeric zone forms (Z07:00, Z0700, Z07, -07:00,
// -0700, -07) and weekday names (Mon/Monday).
//
// Two deliberate divergences, both recorded in docs/expr-gap-analysis.md:
//   - a time-only layout matches Go's year-0 default and then overflows
//     int64 nanoseconds; mbel returns the same wrapped value Go's
//     UnixNano does rather than inventing a range check, so the corpus
//     covers it;
//   - an IANA zone name (Asia/Shanghai) still needs the zone database and
//     is rejected, exactly as `timezone()` rejects it.

///|
/// Fields recovered from a layout match, plus which of them were present.
struct GoTimeFields {
  mut year : Int
  mut month : Int
  mut day : Int
  mut hour : Int
  mut minute : Int
  mut second : Int
  mut nanosecond : Int
  mut offset_minutes : Int
  mut has_year : Bool
  mut has_month : Bool
  mut has_day : Bool
  mut has_hour : Bool
  mut has_minute : Bool
  mut has_second : Bool
  mut has_offset : Bool
  mut pm : Bool
  mut has_pm : Bool
  mut weekday : Int
  mut has_weekday : Bool
}

///|
fn new_go_time_fields() -> GoTimeFields {
  {
    year: 0,
    month: 1,
    day: 1,
    hour: 0,
    minute: 0,
    second: 0,
    nanosecond: 0,
    offset_minutes: 0,
    has_year: false,
    has_month: false,
    has_day: false,
    has_hour: false,
    has_minute: false,
    has_second: false,
    has_offset: false,
    pm: false,
    has_pm: false,
    weekday: -1,
    has_weekday: false,
  }
}

///|
fn gt_month_names() -> Array[(String, Int)] {
  [
    ("january", 1),
    ("february", 2),
    ("march", 3),
    ("april", 4),
    ("may", 5),
    ("june", 6),
    ("july", 7),
    ("august", 8),
    ("september", 9),
    ("october", 10),
    ("november", 11),
    ("december", 12),
  ]
}

///|
fn gt_day_names() -> Array[(String, Int)] {
  [
    ("sunday", 0),
    ("monday", 1),
    ("tuesday", 2),
    ("wednesday", 3),
    ("thursday", 4),
    ("friday", 5),
    ("saturday", 6),
  ]
}

///|
/// Prefix-matches a name at `s[i]`, case-insensitively, comparing only the
/// first `name_len` characters of each candidate. Comparing the input
/// prefix — rather than taking `name_len` characters from the input — is
/// what Go does, and it is required for both "Mon" to accept "Monday" and
/// for the name to be recognised when more input follows it.
fn gt_match_name(
  s : Array[Char],
  i : Int,
  names : Array[(String, Int)],
  fixed_len : Int,
) -> (Int, Int)? {
  for pair in names {
    let (nm, v) = pair
    let nc = nm.to_array()
    // 0 means "compare the candidate's own length" — Go's lookup for a
    // long element ("Monday") compares the whole name, while a short
    // element ("Mon") compares three characters and therefore also
    // accepts the long spelling.
    let len = if fixed_len > 0 { fixed_len } else { nc.length() }
    if nc.length() < len || i + len > s.length() {
      continue
    }
    let mut ok = true
    for j in 0..<len {
      let c = s[i + j]
      let lc = if c >= 'A' && c <= 'Z' {
        (c.to_int() + 32).unsafe_to_char()
      } else {
        c
      }
      if lc != nc[j] {
        ok = false
      }
    }
    if ok {
      return Some((v, i + len))
    }
  }
  None
}

///|
/// Lowercases up to `len` characters of `s` from `start` (used for the
/// two-letter AM/PM marker).
fn gt_lower2(s : Array[Char], start : Int, len : Int) -> String {
  let buf = StringBuilder::new()
  let mut i = 0
  while i < len && start + i < s.length() {
    let c = s[start + i]
    buf.write_char(if c >= 'A' && c <= 'Z' { (c.to_int() + 32).unsafe_to_char() } else { c })
    i += 1
  }
  buf.to_string()
}

///|
fn gt_digits(s : Array[Char], start : Int, want : Int) -> Int? {
  if start + want > s.length() {
    return None
  }
  let mut v = 0
  for i in start..<(start + want) {
    let c = s[i]
    if c < '0' || c > '9' {
      return None
    }
    v = v * 10 + (c.to_int() - 48)
  }
  Some(v)
}

///|
fn gt_digits_var(s : Array[Char], start : Int, want_min : Int, want_max : Int) -> (Int, Int)? {
  let mut i = start
  let mut v = 0
  let mut n = 0
  while i < s.length() && n < want_max {
    let c = s[i]
    if c < '0' || c > '9' {
      break
    }
    v = v * 10 + (c.to_int() - 48)
    i += 1
    n += 1
  }
  if n < want_min {
    return None
  }
  Some((v, i))
}

///|
fn gt_parse_signed_offset(
  s : Array[Char],
  start : Int,
  colon : Bool,
  two_digit_hour : Bool,
) -> (Int, Int)? {
  let n = s.length()
  if start >= n {
    return None
  }
  let sign = match s[start] {
    '+' => 1
    '-' => -1
    _ => return None
  }
  let mut i = start + 1
  let hour : Int = if two_digit_hour {
    match gt_digits(s, i, 2) {
      Some(h) => {
        i += 2
        h
      }
      None => return None
    }
  } else {
    match gt_digits_var(s, i, 1, 2) {
      Some((h, j)) => {
        i = j
        h
      }
      None => return None
    }
  }
  let mut minutes = 0
  if colon {
    if i < n && s[i] == ':' {
      match gt_digits(s, i + 1, 2) {
        Some(m) => {
          minutes = m
          i += 3
        }
        None => return None
      }
    }
  } else if i < n && s[i] >= '0' && s[i] <= '9' {
    match gt_digits(s, i, 2) {
      Some(m) => {
        minutes = m
        i += 2
      }
      None => return None
    }
  }
  Some((sign * (hour * 60 + minutes), i))
}

///|
/// Matches one layout element at `li`, consuming input from `i`.
/// Returns the new input index, or None when the element is not present
/// in the layout at that position.
fn gt_try_element(
  lay : Array[Char],
  li : Int,
  s : Array[Char],
  i : Int,
  f : GoTimeFields,
) -> Int? raise @evaluator.EvalError {
  let ln = lay.length()
  let sn = s.length()
  let at = fn(text : String) -> Bool {
    let t = text.to_array()
    if li + t.length() > ln {
      return false
    }
    for k in 0..<t.length() {
      if lay[li + k] != t[k] {
        return false
      }
    }
    true
  }
  // --- zone forms first (they start with Z or -) ---
  if at("Z07:00") {
    if i < sn && s[i] == 'Z' {
      f.offset_minutes = 0
      f.has_offset = true
      return Some(i + 1)
    }
    match gt_parse_signed_offset(s, i, true, true) {
      Some((off, j)) => {
        f.offset_minutes = off
        f.has_offset = true
        return Some(j)
      }
      None => return None
    }
  }
  if at("Z0700") {
    if i < sn && s[i] == 'Z' {
      f.offset_minutes = 0
      f.has_offset = true
      return Some(i + 1)
    }
    match gt_parse_signed_offset(s, i, false, true) {
      Some((off, j)) => {
        f.offset_minutes = off
        f.has_offset = true
        return Some(j)
      }
      None => return None
    }
  }
  if at("-07:00") {
    match gt_parse_signed_offset(s, i, true, true) {
      Some((off, j)) => {
        f.offset_minutes = off
        f.has_offset = true
        return Some(j)
      }
      None => return None
    }
  }
  if at("-0700") {
    match gt_parse_signed_offset(s, i, false, true) {
      Some((off, j)) => {
        f.offset_minutes = off
        f.has_offset = true
        return Some(j)
      }
      None => return None
    }
  }
  if at("Z07") {
    if i < sn && s[i] == 'Z' {
      f.offset_minutes = 0
      f.has_offset = true
      return Some(i + 1)
    }
    match gt_parse_signed_offset(s, i, false, false) {
      Some((off, j)) => {
        f.offset_minutes = off
        f.has_offset = true
        return Some(j)
      }
      None => return None
    }
  }
  if at("-07") {
    match gt_parse_signed_offset(s, i, false, false) {
      Some((off, j)) => {
        f.offset_minutes = off
        f.has_offset = true
        return Some(j)
      }
      None => return None
    }
  }
  // --- names ---
  if at("January") || at("Jan") {
    // Go's lookup compares the input prefix against the name, so the short
    // element accepts the long spelling too ("Mon" parses "Monday").
    let fixed = if at("January") { 0 } else { 3 }
    match gt_match_name(s, i, gt_month_names(), fixed) {
      Some((m, j)) => {
        f.month = m
        f.has_month = true
        return Some(j)
      }
      None => return None
    }
  }
  if at("Monday") || at("Mon") {
    let fixed = if at("Monday") { 0 } else { 3 }
    match gt_match_name(s, i, gt_day_names(), fixed) {
      Some((d, j)) => {
        f.weekday = d
        f.has_weekday = true
        return Some(j)
      }
      None => return None
    }
  }
  if at("MST") {
    // Go reads a run of letters; an unknown abbreviation yields a
    // fabricated location with a zero offset.
    let mut j = i
    while j < sn && s[j] >= 'A' && s[j] <= 'Z' {
      j += 1
    }
    if j == i {
      return None
    }
    f.has_offset = true
    f.offset_minutes = 0
    return Some(j)
  }
  if at("PM") {
    if i + 2 <= sn {
      let two = gt_lower2(s, i, 2)
      if two == "pm" {
        f.pm = true
        f.has_pm = true
        return Some(i + 2)
      }
      if two == "am" {
        f.pm = false
        f.has_pm = true
        return Some(i + 2)
      }
    }
    return None
  }
  if at("pm") {
    if i + 2 <= sn {
      let two = gt_lower2(s, i, 2)
      if two == "pm" {
        f.pm = true
        f.has_pm = true
        return Some(i + 2)
      }
      if two == "am" {
        f.pm = false
        f.has_pm = true
        return Some(i + 2)
      }
    }
    return None
  }
  // --- numeric fields, longest element first ---
  if at("2006") {
    match gt_digits(s, i, 4) {
      Some(y) => {
        f.year = y
        f.has_year = true
        return Some(i + 4)
      }
      None => return None
    }
  }
  if at("15") {
    match gt_digits(s, i, 2) {
      Some(h) => {
        f.hour = h
        f.has_hour = true
        return Some(i + 2)
      }
      None => return None
    }
  }
  if at("01") {
    match gt_digits(s, i, 2) {
      Some(m) => {
        f.month = m
        f.has_month = true
        return Some(i + 2)
      }
      None => return None
    }
  }
  if at("02") {
    match gt_digits(s, i, 2) {
      Some(d) => {
        f.day = d
        f.has_day = true
        return Some(i + 2)
      }
      None => return None
    }
  }
  if at("_2") {
    let mut j = i
    if j < sn && s[j] == ' ' {
      j += 1
    }
    match gt_digits_var(s, j, 1, 2) {
      Some((d, k)) => {
        f.day = d
        f.has_day = true
        return Some(k)
      }
      None => return None
    }
  }
  if at("03") {
    match gt_digits(s, i, 2) {
      Some(h) => {
        f.hour = h
        f.has_hour = true
        return Some(i + 2)
      }
      None => return None
    }
  }
  if at("04") {
    match gt_digits(s, i, 2) {
      Some(m) => {
        f.minute = m
        f.has_minute = true
        return Some(i + 2)
      }
      None => return None
    }
  }
  if at("05") {
    match gt_digits(s, i, 2) {
      Some(sec) => {
        f.second = sec
        f.has_second = true
        return Some(i + 2)
      }
      None => return None
    }
  }
  if at("06") {
    match gt_digits(s, i, 2) {
      Some(y) => {
        // Go: 69..99 -> 19xx, 00..68 -> 20xx
        f.year = if y >= 69 { 1900 + y } else { 2000 + y }
        f.has_year = true
        return Some(i + 2)
      }
      None => return None
    }
  }
  if at(".000") || at(".999") {
    let want = if at(".000") { 3 } else { 3 }
    let _ = want
    if i < sn && s[i] == '.' {
      let mut j = i + 1
      let mut n = 0
      let mut v = 0
      while j < sn && s[j] >= '0' && s[j] <= '9' && n < 9 {
        v = v * 10 + (s[j].to_int() - 48)
        j += 1
        n += 1
      }
      if n == 0 {
        return None
      }
      while n < 9 {
        v = v * 10
        n += 1
      }
      f.nanosecond = v
      return Some(j)
    }
    return None
  }
  if at("1") {
    match gt_digits_var(s, i, 1, 2) {
      Some((m, j)) => {
        f.month = m
        f.has_month = true
        return Some(j)
      }
      None => return None
    }
  }
  if at("2") {
    match gt_digits_var(s, i, 1, 2) {
      Some((d, j)) => {
        f.day = d
        f.has_day = true
        return Some(j)
      }
      None => return None
    }
  }
  if at("3") {
    match gt_digits_var(s, i, 1, 2) {
      Some((h, j)) => {
        f.hour = h
        f.has_hour = true
        return Some(j)
      }
      None => return None
    }
  }
  if at("4") {
    match gt_digits_var(s, i, 1, 2) {
      Some((m, j)) => {
        f.minute = m
        f.has_minute = true
        return Some(j)
      }
      None => return None
    }
  }
  if at("5") {
    match gt_digits_var(s, i, 1, 2) {
      Some((sec, j)) => {
        f.second = sec
        f.has_second = true
        return Some(j)
      }
      None => return None
    }
  }
  None
}

///|
fn gt_layout_len(lay : Array[Char], li : Int) -> Int {
  matcher(lay, li)
}

///|
fn matcher(lay : Array[Char], li : Int) -> Int {
  let ln = lay.length()
  let at = fn(text : String) -> Bool {
    let t = text.to_array()
    if li + t.length() > ln {
      return false
    }
    for k in 0..<t.length() {
      if lay[li + k] != t[k] {
        return false
      }
    }
    true
  }
  for e in [
    "Z07:00", "Z0700", "-07:00", "-0700", "January", "Monday", "Z07", "-07", "2006",
    "MST", "Jan", "Mon", "15", "01", "02", "_2", "03", "04", "05", "06", ".000", ".999",
    "PM", "pm", "1", "2", "3", "4", "5",
  ] {
    if at(e) {
      return e.to_array().length()
    }
  }
  0
}

///|
fn is_leap(y : Int) -> Bool {
  (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

///|
fn days_in_month(y : Int, m : Int) -> Int {
  match m {
    1 | 3 | 5 | 7 | 8 | 10 | 12 => 31
    4 | 6 | 9 | 11 => 30
    2 => if is_leap(y) { 29 } else { 28 }
    _ => 0
  }
}

///|
/// The weekday of a civil date (0 = Sunday), for Go's weekday validation.
fn civil_weekday(y : Int, m : Int, d : Int) -> Int {
  let days = days_from_civil(y, m, d)
  let w = (days + 4L) % 7L
  (if w < 0L { w + 7L } else { w }).to_int()
}

///|
/// Parses `s` with a Go reference layout, returning nanoseconds since the
/// Unix epoch, or None when the input does not match.
fn go_parse_layout(s : String, layout : String) -> Int64? raise @evaluator.EvalError {
  let sc = s.to_array()
  let lay = layout.to_array()
  let f = new_go_time_fields()
  let ln = lay.length()
  let sn = sc.length()
  let mut li = 0
  let mut i = 0
  while li < ln {
    if i > sn {
      return None
    }
    let el_len = gt_layout_len(lay, li)
    if el_len == 0 {
      // literal: must be present verbatim
      if i >= sn || sc[i] != lay[li] {
        return None
      }
      li += 1
      i += 1
      continue
    }
    match gt_try_element(lay, li, sc, i, f) {
      Some(j) => {
        // After a seconds element Go also accepts a fractional part that
        // the layout does not mention.
        let is_second = el_len == 2 &&
          (lay[li] == '0' && lay[li + 1] == '5' || lay[li] == '5')
        i = j
        if is_second && i < sn && sc[i] == '.' {
          match gt_try_element("05".to_array(), 0, sc, i, f) {
            _ => ()
          }
          let mut j2 = i + 1
          let mut n = 0
          let mut v = 0
          while j2 < sn && sc[j2] >= '0' && sc[j2] <= '9' && n < 9 {
            v = v * 10 + (sc[j2].to_int() - 48)
            j2 += 1
            n += 1
          }
          if n > 0 {
            while n < 9 {
              v = v * 10
              n += 1
            }
            f.nanosecond = v
            i = j2
          }
        }
        li += el_len
      }
      None => return None
    }
  }
  if i != sn {
    return None
  }
  // 12-hour clock
  let mut hour = f.hour
  if f.has_pm {
    if hour < 1 || hour > 12 {
      return None
    }
    if f.pm && hour != 12 {
      hour += 12
    }
    if !f.pm && hour == 12 {
      hour = 0
    }
  }
  if f.month < 1 || f.month > 12 {
    return None
  }
  // Go validates the day against the month (and leap years) once the year
  // is known; without a year it uses year 0, which is a leap year.
  if f.day < 1 || f.day > days_in_month(f.year, f.month) {
    return None
  }
  if hour > 23 || f.minute > 59 || f.second > 59 {
    return None
  }
  if f.has_weekday {
    let w = civil_weekday(f.year, f.month, f.day)
    if w != f.weekday {
      return None
    }
  }
  let days = days_from_civil(f.year, f.month, f.day)
  let secs = days * 86400L +
    (hour * 3600 + f.minute * 60 + f.second).to_int64() -
    f.offset_minutes.to_int64() * 60L
  Some(secs * 1000000000L + f.nanosecond.to_int64())
}
