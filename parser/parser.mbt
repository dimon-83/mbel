// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// parser package: state-machine parser that converts tokens to AST
//
// Ported from Jexl's lib/parser/Parser.js + handlers.js + states.js.
// The parser is a finite state machine that processes tokens one at a
// time and builds an AST with cursor-based tree construction.

///|
/// Parse error carrying a Jexl-style message.
pub(all) suberror ParseError {
  ParseErr(String)
}

///|
/// The Parser is a state machine that converts tokens from the Lexer
/// into an Abstract Syntax Tree (AST), capable of being evaluated.
///
/// Sub-expressions (parenthesized groups, filters, args, object/array
/// values, ternary branches) are handled by recursive sub-parsers whose
/// stop map lists the token types that end them.
#warnings("-unused_mut")
priv struct Parser {
  mut state : String
  mut tree : @ast.AstNode?
  mut cursor : @ast.AstNode?
  mut expr_str : String
  mut relative : Bool
  stop_map : Array[(@grammar.TokenType, String)]
  prec : (String) -> Int
  mut sub_parser : Parser?
  mut parent_stop : Bool
  mut next_ident_encapsulate : Bool
  mut next_ident_relative : Bool
  mut cur_obj_key : String
}

///|
/// Parses an array of tokens into an AST. Returns `None` for an empty
/// expression (no tokens). Equivalent to Jexl's
/// `new Parser(grammar).addTokens(tokens).complete()`.
pub fn parse(tokens : Array[@lexer.Token]) -> @ast.AstNode? raise ParseError {
  parse_with(tokens, @grammar.default_elements())
}

///|
/// Parses tokens against a custom grammar element list, so operator
/// precedence and availability follow the caller's element registry.
/// Mirrors Jexl's `new Parser(grammar).addTokens(tokens).complete()`.
pub fn parse_with(
  tokens : Array[@lexer.Token],
  elements : Array[@grammar.ElementDef]
) -> @ast.AstNode? raise ParseError {
  let p : Parser = new_parser([], "", elements)
  for token in tokens {
    ignore(p.add_token(token))
  }
  p.complete()
}

///|
/// Creates a new Parser with the given stop map.
fn new_parser(
  stop_map : Array[(@grammar.TokenType, String)],
  prefix : String,
  elements : Array[@grammar.ElementDef],
) -> Parser {
  {
    state: "expectOperand",
    tree: None,
    cursor: None,
    expr_str: prefix,
    relative: false,
    stop_map,
    prec: fn(op : String) -> Int { @grammar.precedence_of(elements, op) },
    sub_parser: None,
    parent_stop: false,
    next_ident_encapsulate: false,
    next_ident_relative: false,
    cur_obj_key: "",
  }
}

///|
/// Converts a lexer LiteralValue to an ast Value.
fn litval_to_value(lv : @lexer.LiteralValue) -> @ast.Value {
  match lv {
    @lexer.Bool(b) => @ast.BoolVal(b)
    @lexer.Num(n) => @ast.NumVal(n)
    @lexer.Str(s) => @ast.StrVal(s)
  }
}

// --- State machine tables ---

///|
/// States in which the parser can legally complete (end of expression).
fn is_completable(state : String) -> Bool {
  match state {
    "expectBinOp"
    | "postTransform"
    | "postArgs"
    | "identifier"
    | "ternaryEnd" => true
    _ => false
  }
}

///|
/// States that use a subHandler for sub-expression processing.
fn has_sub_handler(state : String) -> Bool {
  match state {
    "filter"
    | "subExpression"
    | "argVal"
    | "objVal"
    | "arrayVal"
    | "ternaryMid"
    | "ternaryEnd" => true
    _ => false
  }
}

///|
/// End-state map for each subHandler state: maps the closing token type
/// to the state to transition into after the sub-expression completes.
fn end_states(state : String) -> Array[(@grammar.TokenType, String)] {
  match state {
    "filter" => [(@grammar.CloseBracket, "identifier")]
    "subExpression" => [(@grammar.CloseParen, "expectBinOp")]
    "argVal" => [(@grammar.Comma, "argVal"), (@grammar.CloseParen, "postArgs")]
    "objVal" =>
      [(@grammar.Comma, "expectObjKey"), (@grammar.CloseCurl, "expectBinOp")]
    "arrayVal" =>
      [(@grammar.Comma, "arrayVal"), (@grammar.CloseBracket, "expectBinOp")]
    "ternaryMid" => [(@grammar.Colon, "ternaryEnd")]
    _ => []
  }
}

///|
/// Returns the JS-style type name of a token for error messages,
/// e.g. `binaryOp`, `openParen` — matching Jexl's grammar element types.
fn token_type_name(typ : @grammar.TokenType) -> String {
  match typ {
    @grammar.Literal => "literal"
    @grammar.Identifier => "identifier"
    @grammar.BinaryOp => "binaryOp"
    @grammar.UnaryOp => "unaryOp"
    @grammar.Dot => "dot"
    @grammar.OpenBracket => "openBracket"
    @grammar.CloseBracket => "closeBracket"
    @grammar.Pipe => "pipe"
    @grammar.OpenCurl => "openCurl"
    @grammar.CloseCurl => "closeCurl"
    @grammar.Colon => "colon"
    @grammar.Comma => "comma"
    @grammar.OpenParen => "openParen"
    @grammar.CloseParen => "closeParen"
    @grammar.Question => "question"
  }
}

///|
/// Extracts the string value of a token (identifier name or operator symbol).
fn token_str(token : @lexer.Token) -> String {
  match token.value {
    @lexer.Str(s) => s
    _ => token.raw
  }
}

// --- State machine core ---

///|
/// Processes a new token into the AST and manages state transitions.
/// Returns the stop state name when a token in the stop map is
/// encountered, else `None` (tokens can continue).
fn Parser::add_token(
  self : Parser,
  token : @lexer.Token,
) -> String? raise ParseError {
  if self.state == "complete" {
    raise ParseError::ParseErr("Cannot add a new token to a completed Parser")
  }
  let start_expr = self.expr_str
  self.expr_str = self.expr_str + token.raw
  // SubHandler states delegate to the sub-parser
  if has_sub_handler(self.state) {
    if self.sub_parser is None {
      self.start_sub_expression(start_expr)
    }
    let stop_state = self.sub_parser.unwrap().add_token(token)
    if stop_state is Some(_) {
      self.end_sub_expression()
      if self.parent_stop {
        return stop_state
      }
      self.state = stop_state.unwrap()
    }
    return None
  }
  // Non-subHandler states: JS checks the state's tokenTypes first and
  // only consults the stop map when the token is illegal in this state.
  if state_accepts(self.state, token.typ) {
    self.handle_token(token)
    None
  } else {
    match lookup_stop(self.stop_map, token.typ) {
      Some(stop_state) => Some(stop_state)
      None => {
        self.unexpected(token)
        None
      }
    }
  }
}

///|
/// Whether a token type is legal in the given state. Mirrors the
/// tokenTypes maps of Jexl's states.js. Must stay in sync with the
/// match arms of the handle_* functions.
fn state_accepts(state : String, typ : @grammar.TokenType) -> Bool {
  match state {
    "expectOperand" =>
      match typ {
        @grammar.Literal
        | @grammar.Identifier
        | @grammar.UnaryOp
        | @grammar.OpenParen
        | @grammar.OpenCurl
        | @grammar.Dot
        | @grammar.OpenBracket => true
        _ => false
      }
    "expectBinOp" =>
      match typ {
        @grammar.BinaryOp | @grammar.Pipe | @grammar.Dot | @grammar.Question =>
          true
        _ => false
      }
    "expectTransform" =>
      match typ {
        @grammar.Identifier => true
        _ => false
      }
    "expectObjKey" =>
      match typ {
        @grammar.Literal | @grammar.Identifier | @grammar.CloseCurl => true
        _ => false
      }
    "expectKeyValSep" =>
      match typ {
        @grammar.Colon => true
        _ => false
      }
    "postTransform" =>
      match typ {
        @grammar.OpenParen
        | @grammar.BinaryOp
        | @grammar.Dot
        | @grammar.OpenBracket
        | @grammar.Pipe => true
        _ => false
      }
    "postArgs" =>
      match typ {
        @grammar.BinaryOp
        | @grammar.Dot
        | @grammar.OpenBracket
        | @grammar.Pipe => true
        _ => false
      }
    "identifier" =>
      match typ {
        @grammar.BinaryOp
        | @grammar.Dot
        | @grammar.OpenBracket
        | @grammar.OpenParen
        | @grammar.Pipe
        | @grammar.Question => true
        _ => false
      }
    "traverse" =>
      match typ {
        @grammar.Identifier => true
        _ => false
      }
    _ => false
  }
}

///|
/// Looks up a token type in the stop map.
fn lookup_stop(
  map : Array[(@grammar.TokenType, String)],
  typ : @grammar.TokenType,
) -> String? {
  for entry in map {
    let (tt, state) = entry
    if tt == typ {
      return Some(state)
    }
  }
  None
}

///|
/// Dispatches a token to the appropriate handler based on current state
/// and token type. Raises on unexpected tokens.
fn Parser::handle_token(
  self : Parser,
  token : @lexer.Token,
) -> Unit raise ParseError {
  match self.state {
    "expectOperand" => self.handle_expect_operand(token)
    "expectBinOp" => self.handle_expect_bin_op(token)
    "expectTransform" => self.handle_expect_transform(token)
    "expectObjKey" => self.handle_expect_obj_key(token)
    "expectKeyValSep" => self.handle_expect_key_val_sep(token)
    "postTransform" => self.handle_post_transform(token)
    "postArgs" => self.handle_post_args(token)
    "identifier" => self.handle_identifier_state(token)
    "traverse" => self.handle_traverse(token)
    _ => self.unexpected(token)
  }
}

///|
fn Parser::unexpected(
  self : Parser,
  token : @lexer.Token,
) -> Unit raise ParseError {
  raise ParseError::ParseErr(
    "Token " +
    token.raw +
    " (" +
    token_type_name(token.typ) +
    ") unexpected in expression: " +
    self.expr_str,
  )
}

// --- State handlers ---

///|
fn Parser::handle_expect_operand(
  self : Parser,
  token : @lexer.Token,
) -> Unit raise ParseError {
  match token.typ {
    @grammar.Literal => {
      self.place_at_cursor(@ast.literal(litval_to_value(token.value)))
      self.state = "expectBinOp"
    }
    @grammar.Identifier => {
      self.place_at_cursor(@ast.identifier(token_str(token)))
      self.state = "identifier"
    }
    @grammar.UnaryOp => self.place_at_cursor(@ast.unary_expr(token_str(token)))
    @grammar.OpenParen => self.state = "subExpression"
    @grammar.OpenCurl => {
      self.obj_start()
      self.state = "expectObjKey"
    }
    @grammar.Dot => {
      // JS dispatches handlers.dot by token type in every state that
      // accepts dot — expectOperand included.
      self.dot_handler()
      self.state = "traverse"
    }
    @grammar.OpenBracket => {
      self.array_start()
      self.state = "arrayVal"
    }
    _ => self.unexpected(token)
  }
}

///|
fn Parser::handle_expect_bin_op(
  self : Parser,
  token : @lexer.Token,
) -> Unit raise ParseError {
  match token.typ {
    @grammar.BinaryOp => {
      self.binary_op_handler(token)
      self.state = "expectOperand"
    }
    @grammar.Pipe => self.state = "expectTransform"
    @grammar.Dot => {
      self.dot_handler()
      self.state = "traverse"
    }
    @grammar.Question => {
      self.ternary_start()
      self.state = "ternaryMid"
    }
    _ => self.unexpected(token)
  }
}

///|
fn Parser::handle_expect_transform(
  self : Parser,
  token : @lexer.Token,
) -> Unit raise ParseError {
  match token.typ {
    @grammar.Identifier => {
      self.transform_handler(token)
      self.state = "postTransform"
    }
    _ => self.unexpected(token)
  }
}

///|
fn Parser::handle_expect_obj_key(
  self : Parser,
  token : @lexer.Token,
) -> Unit raise ParseError {
  match token.typ {
    @grammar.Literal | @grammar.Identifier => {
      self.obj_key(token)
      self.state = "expectKeyValSep"
    }
    @grammar.CloseCurl => self.state = "expectBinOp"
    _ => self.unexpected(token)
  }
}

///|
fn Parser::handle_expect_key_val_sep(
  self : Parser,
  token : @lexer.Token,
) -> Unit raise ParseError {
  match token.typ {
    @grammar.Colon => self.state = "objVal"
    _ => self.unexpected(token)
  }
}

///|
fn Parser::handle_post_transform(
  self : Parser,
  token : @lexer.Token,
) -> Unit raise ParseError {
  match token.typ {
    @grammar.OpenParen => self.state = "argVal"
    @grammar.BinaryOp => {
      self.binary_op_handler(token)
      self.state = "expectOperand"
    }
    @grammar.Dot => {
      self.dot_handler()
      self.state = "traverse"
    }
    @grammar.OpenBracket => self.state = "filter"
    @grammar.Pipe => self.state = "expectTransform"
    _ => self.unexpected(token)
  }
}

///|
fn Parser::handle_post_args(
  self : Parser,
  token : @lexer.Token,
) -> Unit raise ParseError {
  match token.typ {
    @grammar.BinaryOp => {
      self.binary_op_handler(token)
      self.state = "expectOperand"
    }
    @grammar.Dot => {
      self.dot_handler()
      self.state = "traverse"
    }
    @grammar.OpenBracket => self.state = "filter"
    @grammar.Pipe => self.state = "expectTransform"
    _ => self.unexpected(token)
  }
}

///|
fn Parser::handle_identifier_state(
  self : Parser,
  token : @lexer.Token,
) -> Unit raise ParseError {
  match token.typ {
    @grammar.BinaryOp => {
      self.binary_op_handler(token)
      self.state = "expectOperand"
    }
    @grammar.Dot => {
      self.dot_handler()
      self.state = "traverse"
    }
    @grammar.OpenBracket => self.state = "filter"
    @grammar.OpenParen => {
      self.function_call_handler()
      self.state = "argVal"
    }
    @grammar.Pipe => self.state = "expectTransform"
    @grammar.Question => {
      self.ternary_start()
      self.state = "ternaryMid"
    }
    _ => self.unexpected(token)
  }
}

///|
fn Parser::handle_traverse(
  self : Parser,
  token : @lexer.Token,
) -> Unit raise ParseError {
  match token.typ {
    @grammar.Identifier => {
      self.identifier_handler(token)
      self.state = "identifier"
    }
    _ => self.unexpected(token)
  }
}

// --- Tree construction helpers ---

///|
/// Places a new node at the cursor position (cursor.right), then
/// advances the cursor to the new node. If no cursor exists, sets the
/// tree root. Mirrors Jexl's `_placeAtCursor`.
fn Parser::place_at_cursor(self : Parser, node : @ast.AstNode) -> Unit {
  match self.cursor {
    Some(cursor) => {
      cursor.right = Some(node)
      node.parent = Some(cursor)
    }
    None => self.tree = Some(node)
  }
  self.cursor = Some(node)
}

///|
/// Places a node before the cursor, replacing the current cursor node.
/// The old cursor node becomes a child of the new node.
/// Mirrors Jexl's `_placeBeforeCursor`.
fn Parser::place_before_cursor(self : Parser, node : @ast.AstNode) -> Unit {
  let cursor = self.cursor.unwrap()
  self.cursor = cursor.parent
  self.place_at_cursor(node)
}

///|
/// Marks the parser as complete and returns the AST, or `None` if no
/// tokens were processed. Mirrors Jexl's `complete`.
fn Parser::complete(self : Parser) -> @ast.AstNode? raise ParseError {
  if self.cursor is Some(_) && !is_completable(self.state) {
    raise ParseError::ParseErr("Unexpected end of expression: " + self.expr_str)
  }
  if self.sub_parser is Some(_) {
    self.end_sub_expression()
  }
  self.state = "complete"
  self.tree
}

// --- Sub-expression machinery ---

///|
/// Ends a sub-expression by completing the sub-parser and calling the
/// subHandler for the current state. Mirrors Jexl's `_endSubExpression`.
fn Parser::end_sub_expression(self : Parser) -> Unit raise ParseError {
  let sub = self.sub_parser.unwrap()
  let ast = sub.complete()
  // Handler runs before the sub-parser is cleared: handlers like filter
  // read the sub-parser's `relative` flag.
  self.sub_handler_call(ast)
  self.sub_parser = None
}

///|
/// Starts a sub-expression by creating a new sub-parser whose stop map
/// is the current state's end-state map — or, for states without one
/// (ternaryEnd), the current stop map with `parent_stop` set.
/// Mirrors Jexl's `_startSubExpression`.
fn Parser::start_sub_expression(self : Parser, expr_str : String) -> Unit {
  let es = end_states(self.state)
  let stop_map = if es.length() == 0 {
    self.parent_stop = true
    self.stop_map
  } else {
    es
  }
  self.sub_parser = Some(new_parser(stop_map, expr_str, []))
}

///|
/// Dispatches to the subHandler function for the current state.
fn Parser::sub_handler_call(self : Parser, ast : @ast.AstNode?) -> Unit {
  match self.state {
    "filter" => self.filter_handler(ast)
    "subExpression" => self.sub_expression_handler(ast)
    "argVal" => self.arg_val_handler(ast)
    "objVal" => self.obj_val_handler(ast)
    "arrayVal" => self.array_val_handler(ast)
    "ternaryMid" => self.ternary_mid_handler(ast)
    "ternaryEnd" => self.ternary_end_handler(ast)
    _ => abort("No subHandler for state: " + self.state)
  }
}

// --- Node handlers (ported from handlers.js) ---

///|
/// Handles binaryOp tokens: walks up the parent chain based on
/// precedence, then creates a BinaryExpression node whose left side is
/// the current cursor. Mirrors `handlers.binaryOp`.
fn Parser::binary_op_handler(self : Parser, token : @lexer.Token) -> Unit {
  let op = token_str(token)
  let prec = (self.prec)(op)
  let mut cursor = self.cursor
  let mut parent = match self.cursor {
    Some(c) => c.parent
    None => None
  }
  while parent is Some(_) {
    let p = parent.unwrap()
    if p.operator != "" && (self.prec)(p.operator) >= prec {
      cursor = parent
      parent = p.parent
    } else {
      break
    }
  }
  let left = cursor.unwrap()
  let node = @ast.binary_expr(op, left)
  left.parent = Some(node)
  self.cursor = parent
  self.place_at_cursor(node)
}

///|
/// Handles dot tokens: sets encapsulate/relative flags for the next
/// identifier. Mirrors `handlers.dot`.
fn Parser::dot_handler(self : Parser) -> Unit {
  let cursor = self.cursor
  self.next_ident_encapsulate = match cursor {
    Some(c) =>
      c.node_type != @ast.UnaryExpressionNode &&
      (c.node_type != @ast.BinaryExpressionNode || c.right is Some(_))
    None => false
  }
  self.next_ident_relative = match cursor {
    None => true
    Some(_) => !self.next_ident_encapsulate
  }
  if self.next_ident_relative {
    self.relative = true
  }
}

///|
/// Handles identifier tokens: creates an Identifier node, handling
/// encapsulation (chained access) and relative paths.
/// Mirrors `handlers.identifier`.
fn Parser::identifier_handler(self : Parser, token : @lexer.Token) -> Unit {
  let node = @ast.identifier(token_str(token))
  if self.next_ident_encapsulate {
    node.from = self.cursor
    self.place_before_cursor(node)
    self.next_ident_encapsulate = false
  } else {
    if self.next_ident_relative {
      node.relative = true
      self.next_ident_relative = false
    }
    self.place_at_cursor(node)
  }
}

///|
/// Handles array literal start: places an ArrayLiteral node.
/// Mirrors `handlers.arrayStart`.
fn Parser::array_start(self : Parser) -> Unit {
  self.place_at_cursor(@ast.array_literal())
}

///|
/// Handles an array literal element value from a sub-expression.
/// Mirrors `handlers.arrayVal`.
fn Parser::array_val_handler(self : Parser, ast : @ast.AstNode?) -> Unit {
  match ast {
    Some(node) => self.cursor.unwrap().array_value.push(node)
    None => ()
  }
}

///|
/// Handles object literal start: places an ObjectLiteral node.
/// Mirrors `handlers.objStart`.
fn Parser::obj_start(self : Parser) -> Unit {
  self.place_at_cursor(@ast.object_literal())
}

///|
/// Queues an object literal key. Mirrors `handlers.objKey`.
fn Parser::obj_key(self : Parser, token : @lexer.Token) -> Unit {
  self.cur_obj_key = token_str(token)
}

///|
/// Handles an object literal value from a sub-expression.
/// Mirrors `handlers.objVal`.
fn Parser::obj_val_handler(self : Parser, ast : @ast.AstNode?) -> Unit {
  match ast {
    Some(node) => self.cursor.unwrap().obj_value.push((self.cur_obj_key, node))
    None => ()
  }
}

///|
/// Handles transform tokens: wraps the cursor in a FunctionCall with
/// pool='transforms'. Mirrors `handlers.transform`.
fn Parser::transform_handler(self : Parser, token : @lexer.Token) -> Unit {
  let node = @ast.function_call(token_str(token), "transforms")
  node.args = [self.cursor.unwrap()]
  self.place_before_cursor(node)
}

///|
/// Handles function call start: wraps the cursor (an identifier) in a
/// FunctionCall with pool='functions'. Mirrors `handlers.functionCall`.
fn Parser::function_call_handler(self : Parser) -> Unit {
  let cursor = self.cursor.unwrap()
  let node = @ast.function_call(cursor.ident_name, "functions")
  self.place_before_cursor(node)
}

///|
/// Handles filter sub-expression completion: wraps the cursor in a
/// FilterExpression. Mirrors `handlers.filter`.
fn Parser::filter_handler(self : Parser, ast : @ast.AstNode?) -> Unit {
  match ast {
    Some(expr) => {
      let relative = self.sub_parser.unwrap().relative
      let subject = self.cursor.unwrap()
      let node = @ast.filter_expression(expr, relative, subject)
      self.place_before_cursor(node)
    }
    None => ()
  }
}

///|
/// Handles sub-expression completion: places the sub-AST at the cursor.
/// Mirrors `handlers.subExpression`.
fn Parser::sub_expression_handler(self : Parser, ast : @ast.AstNode?) -> Unit {
  match ast {
    Some(node) => self.place_at_cursor(node)
    None => ()
  }
}

///|
/// Handles a transform/function argument value from a sub-expression.
/// Mirrors `handlers.argVal`.
fn Parser::arg_val_handler(self : Parser, ast : @ast.AstNode?) -> Unit {
  match ast {
    Some(node) => self.cursor.unwrap().args.push(node)
    None => ()
  }
}

///|
/// Handles ternary start: wraps the entire tree in a ConditionalExpression.
/// Mirrors `handlers.ternaryStart`.
fn Parser::ternary_start(self : Parser) -> Unit {
  let cond = @ast.conditional()
  cond.cond_test = self.tree
  self.tree = Some(cond)
  self.cursor = Some(cond)
}

///|
/// Handles ternary consequent (mid) sub-expression completion.
/// Mirrors `handlers.ternaryMid`.
fn Parser::ternary_mid_handler(self : Parser, ast : @ast.AstNode?) -> Unit {
  self.cursor.unwrap().consequent = ast
}

///|
/// Handles ternary alternate (end) sub-expression completion.
/// Mirrors `handlers.ternaryEnd`.
fn Parser::ternary_end_handler(self : Parser, ast : @ast.AstNode?) -> Unit {
  self.cursor.unwrap().alternate = ast
}
