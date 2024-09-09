(import ../../jlsl)
(use ./util)
(import ../shape)
(use ../../jlsl/prelude)

(defn- make-let-macro [new-vars? bindings body]
  (def [field bindings body] (if (keyword? bindings)
    [bindings (first body) (drop 1 body)]
    [nil bindings body]))
  (def bindings (seq [[name <value>] :in (partition 2 bindings)] [name <value> (gensym)]))
  (def <with-bindings> (map (fn [[name _ $value]] (tuple/brackets name $value)) bindings))
  (def with-name (if new-vars? "let" "with"))
  (with-syms [$subject $field] ~(do
    ,;(catseq [[name <value> $value] :in bindings]
      [~(def ,$value (,jlsl/coerce-expr ,<value>))
       ;(if new-vars?
        [~(def ,name (,jlsl/variable/new ,(string name) (,jlsl/expr/type ,$value)))]
        [])])
    (def ,$subject (do ,;body))
    ,;(if field
      [~(as-macro ,assertf (,shape/is? ,$subject) "%q is not a shape" ,$subject)
       ~(,shape/map-field ,$subject ,field (fn [,$field]
         (,jlsl/with-expr ,<with-bindings> [] ,$field ,with-name)))]
      [~(if (,shape/is? ,$subject)
        (,shape/map ,$subject (fn [,$field]
          (,jlsl/with-expr ,<with-bindings> [] ,$field ,with-name)))
        (,jlsl/with-expr ,<with-bindings> [] (,jlsl/coerce-expr ,$subject) ,with-name))])
    )))

(defmacro gl/let
  ````
  Like `let`, but creates GLSL bindings instead of a Janet bindings. You can use this
  to reference an expression multiple times while only evaluating it once in the resulting
  shader.

  For example:

  ```
  (let [s (sin t)]
    (+ s s))
  ```

  Produces GLSL code like this:

  ```
  sin(t) + sin(t)
  ```

  Because `s` refers to the GLSL *expression* `(sin t)`.

  Meanwhile:

  ```
  (gl/let [s (sin t)]
    (+ s s))
  ```

  Produces GLSL code like this:

  ```
  float let(float s) {
    return s + s;
  }

  let(sin(t))
  ```

  Or something equivalent. Note that the variable is hoisted into an immediately-invoked function
  because it's the only way to introduce a new identifier in a GLSL expression context.

  You can also use Bauble's underscore notation to fit this into a pipeline:

  ```
  (s + s | gl/let [s (sin t)] _)
  ```

  If the body of the `gl/let` returns a shape, the bound variable will be available in all of its
  fields. If you want to refer to variables or expressions that are only available in color fields,
  pass a keyword as the first argument:

  ```
  (gl/let :color [banding (sin depth)]
    (sphere 100 | blinn-phong [1 banding 0]))
  ```
  ````
  [bindings & body]
  (make-let-macro true bindings body))

(defmacro gl/with
  ````
  Like `gl/let`, but instead of creating a new binding, it alters the value of an existing
  variable. You can use this to give new values to dynamic variables. For example:

  ```
  # implement your own `move`
  (gl/with [p (- p [0 50 0])] (sphere 50))
  ```

  You can also use Bauble's underscore notation to fit this into a pipeline:

  ```
  (sphere 50 | gl/with [p (- p [0 50 0])] _)
  ```

  You can -- if you really want -- use this to alter `P` or `Q` to not refer to the point in
  global space, or use it to pretend that `ray-dir` is actually a different angle.

  The variables you change in `gl/with` will, by default, apply to all of the fields of a shape.
  You can pass a keyword as the first argument to only change a particular field. This allows you
  to refer to variables that only exist in color expressions:

  ```
  (gl/with :color [normal (normal + (perlin p * 0.1))]
    (sphere 100 | blinn-phong [1 0 0] | move [-50 0 0]))
  ```
  ````
  [bindings & body]
  (make-let-macro false bindings body))