// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// ast package: AST node types for parsed expressions

///|
/// Discriminant for the different AST node types produced by the Parser.
pub(all) enum NodeType {
  LiteralNode
  IdentifierNode
  BinaryExpressionNode
  UnaryExpressionNode
  ConditionalExpressionNode
  ArrayLiteralNode
  ObjectLiteralNode
  FilterExpressionNode
  FunctionCallNode
} derive(Debug, Eq)

///|
/// A runtime value. Used for literal AST nodes and evaluation results.
/// `NullVal` and `UndefVal` distinguish JavaScript's `null` from `undefined`.
pub(all) enum Value {
  BoolVal(Bool)
  NumVal(Double)
  StrVal(String)
  ArrayVal(Array[Value])
  ObjectVal(Array[(String, Value)])
  NullVal
  UndefVal
} derive(Debug)

///|
/// An AST node. Uses mutable fields because the Parser builds trees
/// incrementally — it places a node at the cursor, then later sets
/// `right`, `from`, `consequent`, `alternate`, etc. on previously
/// placed nodes.
///
/// Field layout mirrors Jexl's dynamic JS object properties:
///   Literal          → value
///   Identifier       → ident_name, from?, relative
///   BinaryExpression → operator, left, right
///   UnaryExpression  → operator, right
///   Conditional      → cond_test, consequent?, alternate
///   ArrayLiteral     → array_value
///   ObjectLiteral    → obj_value (insertion-ordered key→node pairs)
///   FilterExpression → filter_expr, filter_relative, subject
///   FunctionCall     → func_name, args, pool
#warnings("-unused_mut")
pub(all) struct AstNode {
  mut node_type : NodeType
  // Literal
  mut value : Value
  // Identifier
  mut ident_name : String
  mut from : AstNode?
  mut relative : Bool
  // BinaryExpression / UnaryExpression
  mut operator : String
  mut left : AstNode?
  mut right : AstNode?
  // ConditionalExpression
  mut cond_test : AstNode?
  mut consequent : AstNode?
  mut alternate : AstNode?
  // ArrayLiteral
  mut array_value : Array[AstNode]
  // ObjectLiteral (insertion-ordered key→node pairs)
  mut obj_value : Array[(String, AstNode)]
  // FilterExpression
  mut filter_expr : AstNode?
  mut subject : AstNode?
  mut filter_relative : Bool
  // FunctionCall
  mut func_name : String
  mut args : Array[AstNode]
  mut pool : String
  // Parent pointer (non-enumerable in JS, used by Parser cursor traversal)
  mut parent : AstNode?
}

///|
/// Creates a Literal AST node.
pub fn literal(val : Value) -> AstNode {
  {
    node_type: LiteralNode,
    value: val,
    ident_name: "",
    from: None,
    relative: false,
    operator: "",
    left: None,
    right: None,
    cond_test: None,
    consequent: None,
    alternate: None,
    array_value: [],
    obj_value: [],
    filter_expr: None,
    subject: None,
    filter_relative: false,
    func_name: "",
    args: [],
    pool: "",
    parent: None,
  }
}

///|
/// Creates an Identifier AST node.
pub fn identifier(name : String) -> AstNode {
  let n = literal(UndefVal)
  n.node_type = IdentifierNode
  n.ident_name = name
  n
}

///|
/// Creates a BinaryExpression AST node with the given operator and left operand.
/// `right` is set later by the parser.
pub fn binary_expr(op : String, left : AstNode) -> AstNode {
  let n = literal(UndefVal)
  n.node_type = BinaryExpressionNode
  n.operator = op
  n.left = Some(left)
  n
}

///|
/// Creates a UnaryExpression AST node with the given operator.
/// `right` is set later by the parser.
pub fn unary_expr(op : String) -> AstNode {
  let n = literal(UndefVal)
  n.node_type = UnaryExpressionNode
  n.operator = op
  n
}

///|
/// Creates a ConditionalExpression AST node.
/// `cond_test` is set by the parser; consequent/alternate are filled by sub-parsers.
pub fn conditional() -> AstNode {
  let n = literal(UndefVal)
  n.node_type = ConditionalExpressionNode
  n
}

///|
/// Creates an ArrayLiteral AST node with an empty value array.
pub fn array_literal() -> AstNode {
  let n = literal(UndefVal)
  n.node_type = ArrayLiteralNode
  n.array_value = []
  n
}

///|
/// Creates an ObjectLiteral AST node with an empty value array.
pub fn object_literal() -> AstNode {
  let n = literal(UndefVal)
  n.node_type = ObjectLiteralNode
  n.obj_value = []
  n
}

///|
/// Creates a FilterExpression AST node.
pub fn filter_expression(
  expr : AstNode,
  relative : Bool,
  subject : AstNode,
) -> AstNode {
  let n = literal(UndefVal)
  n.node_type = FilterExpressionNode
  n.filter_expr = Some(expr)
  n.filter_relative = relative
  n.subject = Some(subject)
  n
}

///|
/// Creates a FunctionCall AST node.
pub fn function_call(name : String, pool : String) -> AstNode {
  let n = literal(UndefVal)
  n.node_type = FunctionCallNode
  n.func_name = name
  n.pool = pool
  n.args = []
  n
}

///|
/// Structural equality on Values — mirrors JS `toEqual` semantics used
/// by the Jexl Jest suite for AST comparisons.
pub fn value_equal(a : Value, b : Value) -> Bool {
  match (a, b) {
    (BoolVal(x), BoolVal(y)) => x == y
    (NumVal(x), NumVal(y)) => x == y
    (StrVal(x), StrVal(y)) => x == y
    (ArrayVal(x), ArrayVal(y)) => {
      if x.length() != y.length() {
        return false
      }
      for i in 0..<x.length() {
        if !value_equal(x[i], y[i]) {
          return false
        }
      }
      true
    }
    (ObjectVal(x), ObjectVal(y)) => {
      if x.length() != y.length() {
        return false
      }
      for i in 0..<x.length() {
        let (kx, vx) = x[i]
        let (ky, vy) = y[i]
        if kx != ky || !value_equal(vx, vy) {
          return false
        }
      }
      true
    }
    (NullVal, NullVal) => true
    (UndefVal, UndefVal) => true
    (_, _) => false
  }
}

///|
/// Structural equality on AST nodes — compares the fields relevant to
/// each node type, ignoring the `parent` pointer. Mirrors JS `toEqual`.
pub fn ast_equal(a : AstNode, b : AstNode) -> Bool {
  if a.node_type != b.node_type {
    return false
  }
  match a.node_type {
    LiteralNode => value_equal(a.value, b.value)
    IdentifierNode =>
      a.ident_name == b.ident_name &&
      a.relative == b.relative &&
      option_equal(a.from, b.from)
    BinaryExpressionNode =>
      a.operator == b.operator &&
      node_equal(a.left, b.left) &&
      node_equal(a.right, b.right)
    UnaryExpressionNode =>
      a.operator == b.operator && node_equal(a.right, b.right)
    ConditionalExpressionNode =>
      node_equal(a.cond_test, b.cond_test) &&
      option_equal(a.consequent, b.consequent) &&
      option_equal(a.alternate, b.alternate)
    ArrayLiteralNode => {
      let x = a.array_value
      let y = b.array_value
      if x.length() != y.length() {
        return false
      }
      for i in 0..<x.length() {
        if !ast_equal(x[i], y[i]) {
          return false
        }
      }
      true
    }
    ObjectLiteralNode => {
      let x = a.obj_value
      let y = b.obj_value
      if x.length() != y.length() {
        return false
      }
      for i in 0..<x.length() {
        let (kx, vx) = x[i]
        let (ky, vy) = y[i]
        if kx != ky || !ast_equal(vx, vy) {
          return false
        }
      }
      true
    }
    FilterExpressionNode =>
      a.filter_relative == b.filter_relative &&
      node_equal(a.filter_expr, b.filter_expr) &&
      node_equal(a.subject, b.subject)
    FunctionCallNode =>
      a.func_name == b.func_name &&
      a.pool == b.pool &&
      ({
        let x = a.args
        let y = b.args
        if x.length() != y.length() {
          return false
        }
        for i in 0..<x.length() {
          if !ast_equal(x[i], y[i]) {
            return false
          }
        }
        true
      })
  }
}

///|
/// Compares two required sub-node fields.
fn node_equal(a : AstNode?, b : AstNode?) -> Bool {
  match (a, b) {
    (Some(x), Some(y)) => ast_equal(x, y)
    (None, None) => true
    (_, _) => false
  }
}

///|
/// Compares two optional sub-node fields.
fn option_equal(a : AstNode?, b : AstNode?) -> Bool {
  node_equal(a, b)
}
