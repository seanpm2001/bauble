(defmacro view
  "A shorthand for `(set subject _)` that fits nicely into pipe notation, e.g. `(sphere 50 | view)`."
  [subject]
  ~(set subject ,subject))

(var subject
  "A variable that determines what Bauble will render.\n\nYou can set this variable explicitly to change your focus, or use the `view` macro to change your focus. If you don't set a subject, Bauble will render the last expression in your script that it knows how to render."
  nil)

(import ../jlsl)
(use ./dynvars)
(use ./util)
(import ./syntax)
(import ./fields)
(import ../jlsl/prelude :prefix "" :export true)

(defn- typecheck [expr expected]
  (def actual (jlsl/expr/type expr))
  (assertf (= actual expected)
    "type mismatch: expected %q, got %q"
    (jlsl/show-type expected)
    (jlsl/show-type actual)))

(defmacro- defshape [name bindings docstring & body]
  (assert (string? docstring))
  ~(defn ,name ,docstring ,bindings
    ,;(seq [param :in bindings]
      ~(def ,param (,jlsl/coerce-expr ,param)))
    (fields/distance-2d (jlsl/do
      ,;(syntax/expand body)))))

(defmacro- deftransform [name bindings docstring & body]
  (assert (string? docstring))
  ~(defn ,name ,docstring ,bindings
    ,;(seq [param :in (drop 1 bindings)]
      ~(def ,param (,jlsl/coerce-expr ,param)))
    ,;(syntax/expand body)))

(defshape circle [r]
  "it a circle"
  (- (length q) r))

(defshape rect [size]
  "it a box"
  (var d (- (abs q) (vec2 ,size)))
  (+ (length (max d 0)) (min (max d.x d.y) 0)))

# TODO: this should either modify p or q, depending on fields
(deftransform move [fields offset]
  "translate"
  (typecheck offset (fields/type fields))
  (fields/map fields (fn [expr]
    (jlsl/with "move" [q (- q offset)] ,expr))))

(defn color [fields color-expression]
  (struct/with-proto fields :color (jlsl/coerce-expr color-expression)))

(defmacro .
  "Behaves like `.` in GLSL, for accessing components of a vector or struct. Can be combined with swizzling."
  [expr field]
  [jlsl/expr/dot [jlsl/coerce-expr expr] ['quote field]])
