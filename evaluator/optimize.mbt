// SPDX-License-Identifier: Apache-2.0
// mbel — MoonBit Expression Language
// evaluator package: constant-folding optimizer pass (expr's `fold`).
//
// Bottom-up rewrite: sub-trees whose children are all literals and
// whose operator is a default pure operator are computed at compile
// time. Operators registered at runtime (custom add_binary_op) and
// short-circuit forms (&&, ||, ??) are never folded, so folding is
// observationally equivalent to evaluation.

///|
/// Folds constant sub-expressions in place and returns the (possibly
/// unchanged) root. Purely structural: identifiers, filters, and
/// calls are descended into but never replaced.
pub fn constant_fold(ast : @ast.AstNode) -> @ast.AstNode {
  fold_node(ast)
}

///|
fn fold_node(node : @ast.AstNode) -> @ast.AstNode {
  match node.node_type {
    @ast.BinaryExpressionNode => {
      match node.left {
        Some(l) => node.left = Some(fold_node(l))
        None => ()
      }
      match node.right {
        Some(r) => node.right = Some(fold_node(r))
        None => ()
      }
      fold_binary(node)
    }
    @ast.UnaryExpressionNode => {
      match node.right {
        Some(r) => {
          let folded = fold_node(r)
          node.right = Some(folded)
          if node.operator == "!" && folded.node_type == @ast.LiteralNode {
            return @ast.literal(@ast.BoolVal(!truthy(folded.value)))
          }
        }
        None => ()
      }
      node
    }
    @ast.ConditionalExpressionNode => {
      match node.cond_test {
        Some(t) => node.cond_test = Some(fold_node(t))
        None => ()
      }
      match node.consequent {
        Some(c) => node.consequent = Some(fold_node(c))
        None => ()
      }
      match node.alternate {
        Some(a) => node.alternate = Some(fold_node(a))
        None => ()
      }
      node
    }
    @ast.ArrayLiteralNode => {
      for i in 0..<node.array_value.length() {
        node.array_value[i] = fold_node(node.array_value[i])
      }
      node
    }
    @ast.ObjectLiteralNode => {
      for i in 0..<node.obj_value.length() {
        let (k, v) = node.obj_value[i]
        node.obj_value[i] = (k, fold_node(v))
      }
      node
    }
    @ast.FilterExpressionNode => {
      match node.filter_expr {
        Some(e) => node.filter_expr = Some(fold_node(e))
        None => ()
      }
      match node.subject {
        Some(s) => node.subject = Some(fold_node(s))
        None => ()
      }
      node
    }
    @ast.FunctionCallNode => {
      for i in 0..<node.args.length() {
        node.args[i] = fold_node(node.args[i])
      }
      node
    }
    @ast.IdentifierNode => {
      match node.from {
        Some(f) => node.from = Some(fold_node(f))
        None => ()
      }
      node
    }
    @ast.SequenceNode => {
      for i in 0..<node.args.length() {
        let item = node.args[i]
        if item.node_type is @ast.VariableDeclaratorNode {
          if item.args.length() > 0 {
            item.args[0] = fold_node(item.args[0])
          }
        } else {
          node.args[i] = fold_node(item)
        }
      }
      node
    }
    @ast.SliceNode => {
      match node.subject {
        Some(s) => node.subject = Some(fold_node(s))
        None => ()
      }
      match node.slice_from {
        Some(f) => node.slice_from = Some(fold_node(f))
        None => ()
      }
      match node.slice_to {
        Some(t) => node.slice_to = Some(fold_node(t))
        None => ()
      }
      node
    }
    @ast.VariableDeclaratorNode => {
      if node.args.length() > 0 {
        node.args[0] = fold_node(node.args[0])
      }
      node
    }
    @ast.LiteralNode | @ast.PointerNode => node
  }
}

///|
/// Computes a binary node whose operands are both literals, using the
/// default (pure) operator table. Returns the original node when the
/// operator is not foldable or evaluation raises (e.g. invalid regex).
fn fold_binary(node : @ast.AstNode) -> @ast.AstNode {
  let op = node.operator
  // Short-circuit and user-extensible forms stay unfolded.
  match op {
    "&&" | "||" | "??" | "matches" => return node
    _ => ()
  }
  match (node.left, node.right) {
    (Some(l), Some(r)) =>
      if l.node_type == @ast.LiteralNode && r.node_type == @ast.LiteralNode {
        match find_bin(default_binary_ops(), op) {
          Some(f) => @ast.literal(f(l.value, r.value)) catch { _ => node }
          None => node
        }
      } else {
        node
      }
    (_, _) => node
  }
}
