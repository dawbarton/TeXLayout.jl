# AST node representation shared by parser and layout.

"""
An AST node.  Leaf nodes (chars, spaces, standalone commands) have an empty
`children` vector and carry their source text in `value`.  Interior nodes
carry children and may carry auxiliary text in `value` (e.g. the command name
for `NodeKind.Accent`).

The `width` field is meaningful only for `NodeKind.Space` nodes; it carries the
explicit horizontal space in em units (may be negative for `\\!`, etc.).
All other node kinds leave it at the default of `0.0`.
"""
struct Node
    kind::NodeKind.T
    value::String           # source text for leaf nodes; command name for interior
    children::Vector{Node}
    width::Float64          # em units; NodeKind.Space only, 0.0 otherwise
end

# Convenience constructors
Node(kind::NodeKind.T, value::String) = Node(kind, value, Node[], 0.0)
Node(kind::NodeKind.T, children::Vector{Node}) = Node(kind, "", children, 0.0)
Node(kind::NodeKind.T, value::String, children::Vector{Node}) = Node(kind, value, children, 0.0)

"""Construct a `NodeKind.Space` node carrying an explicit horizontal width in em."""
space_node(w::Real) = Node(NodeKind.Space, "", Node[], Float64(w))

# ── Recursive-descent implementation ─────────────────────────────────────────

# Extract the plain-text content of a node as a string.  Used to recover the
# operator name from the braced argument of \operatorname{…}.
function _node_text(node::Node)::String
    node.kind === NodeKind.Char    && return node.value
    node.kind === NodeKind.Command && return startswith(node.value, "\\") ? node.value[2:end] : node.value
    (node.kind === NodeKind.Sequence || node.kind === NodeKind.Group) &&
        return join(_node_text(c) for c in node.children)
    return ""
end
