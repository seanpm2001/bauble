(use ./import)
(use ./transforms)

(defhelper- :vec3 safe-div [:vec3 a :vec3 b]
  (return [
    (if (= b.x 0) 0 (a.x / b.x))
    (if (= b.y 0) 0 (a.y / b.y))
    (if (= b.z 0) 0 (a.z / b.z))
    ]))

(overload :vec2 safe-div [:vec2 a :vec2 b]
  (return [
    (if (= b.x 0) 0 (a.x / b.x))
    (if (= b.y 0) 0 (a.y / b.y))
    ]))

(defmacro- make-tiler [name variable & loop-body]
  ~(defn- ,name [$index distance-field other-field size limit sample-from sample-to]
    (sugar (if limit
      (jlsl/do
        (var size size)
        (var base-index (,variable | safe-div size | round))
        (var look-direction (,variable - (size * base-index) | sign))
        (var limit limit)
        (var limit-start (limit - 1 / 2 | floor -))
        (var limit-end (limit / 2 | floor))
        (var start-logical (sample-from * look-direction + base-index))
        (var end-logical (sample-to * look-direction + base-index))
        (set start-logical (clamp start-logical limit-start limit-end))
        (set end-logical (clamp end-logical limit-start limit-end))
        (var start (min start-logical end-logical))
        (var end (max start-logical end-logical))
        ,;loop-body)
      (jlsl/do
        (var size size)
        (var base-index (,variable | safe-div size | round))
        (var look-direction (,variable - (size * base-index) | sign))
        (var start-logical (sample-from * look-direction + base-index))
        (var end-logical (sample-to * look-direction + base-index))
        (var start (min start-logical end-logical))
        (var end (max start-logical end-logical))
        ,;loop-body)))))

(make-tiler tile-distance-2d q
  (var nearest 1e20)
  (for (var y start.y) (<= y end.y) (++ y)
    (for (var x start.x) (<= x end.x) (++ x)
      (with [$index [x y] q (- q (size * $index))]
        (set nearest (min nearest distance-field)))))
  nearest)

(make-tiler tile-distance-3d p
  (var nearest 1e20)
  (for (var z start.z) (<= z end.z) (++ z)
    (for (var y start.y) (<= y end.y) (++ y)
      (for (var x start.x) (<= x end.x) (++ x)
        (with [$index [x y z] p (- p (size * $index))]
          (set nearest (min nearest distance-field))))))
  nearest)

(make-tiler tile-other-2d q
  (var nearest 1e20)
  (var nearest-index [0 0])
  (for (var y start.y) (<= y end.y) (++ y)
    (for (var x start.x) (<= x end.x) (++ x)
      (with [$index [x y] q (- q (size * $index))]
        (var dist distance-field)
        (if (< dist nearest) (do
          (set nearest dist)
          (set nearest-index $index))))))
  (with [$index nearest-index q (- q (size * $index))]
    other-field))

(make-tiler tile-other-3d p
  (var nearest 1e20)
  (var nearest-index [0 0 0])
  (for (var z start.z) (<= z end.z) (++ z)
    (for (var y start.y) (<= y end.y) (++ y)
      (for (var x start.x) (<= x end.x) (++ x)
        (with [$index [x y z] p (- p (size * $index))]
          (var dist distance-field)
          (if (< dist nearest) (do
            (set nearest dist)
            (set nearest-index $index)))))))
  (with [$index nearest-index p (- p (size * $index))]
    other-field))

(sugar (defn- simple-tile [coord $index expr size limit]
  (gl/let [size size]
    (def index-expr (let [index (coord | safe-div size | round)]
        (if limit
          (gl/let [limit limit]
            (index | clamp (limit - 1 / 2 | floor -) (limit / 2 | floor)))
          index)))
      (gl/with [$index index-expr
                coord (- coord (* size $index))]
        expr))))

(defn- tile-aux [shape $index size limit oversample sample-from sample-to]
  (def size (coerce-to-domain size shape))
  (def limit (if limit (coerce-to-domain limit shape)))
  (def [coord tile-distance tile-other]
    (case (shape/type shape)
      jlsl/type/vec2 [q tile-distance-2d tile-other-2d]
      jlsl/type/vec3 [p tile-distance-3d tile-other-3d]))
  (def sample-from (coerce-to-domain (or sample-from 0) shape))
  (def sample-to (coerce-to-domain (or sample-to 1) shape))

  (if oversample
    (shape/map-fields shape (fn [name expr]
      (case name
        :distance (tile-distance $index expr nil size limit sample-from sample-to)
        (tile-other $index (shape/distance shape) expr size limit sample-from sample-to))))
    (shape/map shape (fn [expr]
      (simple-tile coord $index expr size limit)))))

# TODO: oversample should be a flag; you shouldn't have to pass a boolean?
(defnamed tile [shape size :?limit :?oversample :?sample-from :?sample-to]
  ````
  Repeat the region of space `size` units around the origin. Pass `:limit` to constrain
  the number of repetitions. See `tile:` or `tile*` if you want to produce a shape that
  varies as it repeats.

  To repeat space only along some axes, pass `0`. For example, to only tile in the `y` direction:

  ```example
  (tile (ball 50) [0 100 0])
  ```

  If you're repeating a shape that is not symmetric, you can use `:oversample true` to evaluate
  multiple instances at each pass, essentially considering the distance not only to this
  tile, but also to neighboring tiles. Compare these two distance fields:

  ```example
  (rect 30 | rotate 0.3 | tile [80 80] :oversample false)
  ```
  ```example
  (rect 30 | rotate 0.3 | tile [80 80] :oversample true)
  ```

  The default oversampling is `:sample-from 0` `:sample-to 1`, which means looking at one adjacent
  tile, asymmetrically based on the location of the point (so when evaluating a point near
  the right edge of a tile, it will look at the adjacent tile to the right, but not the tile
  to the left). By passing `:sample-from -1`, you can also look at the tile to the left.
  By passing `:sample-from 0 :sample-to [2 1 1]`, it will look at two tiles to the right in the
  `x` direction, and one tile up/down/in/out.

  This can be useful when raymarching a 3D space where each tile is quite different, but note
  that it's very costly to increase these values. If you're tiling a 3D shape in all directions,
  the default `:oversample` parameters will do 8 distance field evaluations;
  `:sample-from -1` `:sample-to 1` will do 27.
  ````
  (def $index (jlsl/variable/new "tile-index" (shape/type shape)))
  (tile-aux shape $index size limit oversample sample-from sample-to))

(defnamed tile* [size get-shape :?limit :?oversample :?sample-from :?sample-to]
  ````
  Like `tile`, but the shape is a result of invoking `get-shape` with one argument,
  a GLSL variable referring to the current index in space. Unlike `tile`, `size` must
  be a vector that determines the dimension of the index variable.

  ```example
  (tile* [10 10] (fn [$i] 
    (circle 5 
    | color (hsv (hash $i) 0.5 1))))
  ```

  You can use this to generate different shapes or colors at every sampled tile. The index
  will be a vector with integral components that represents  being considered. So for
  example, in 3D, the shape at the origin has an index of `[0 0 0]` and the shape above
  it has an index of `[0 1 0]`.
  ````
  (def size (jlsl/coerce-expr size))
  (def $index (jlsl/variable/new "tile-index" (jlsl/expr/type size)))
  (def shape (get-shape $index))
  (tile-aux shape $index size limit oversample sample-from sample-to))

(defmacro tile:
  ````
  Like `tile*`, but its first argument should be a form that will
  become the body of the function. Basically, it's a way to create
  a repeated shape where each instance of the shape varies, and it's
  written in a way that makes it conveniently fit into a pipeline:

  ```example
  (circle 5 
  | color (hsv (hash $i) 0.5 1) 
  | tile: $i [10 10])
  ```
  ````
  [shape $i & args]
  ~(,tile* ,;args (fn [,$i] ,shape)))

(sugar (defn- simple-radial [coord plane rotate $index expr count]
  (gl/let [count count angular-size (tau / count)]
    (gl/with [$index (atan2 plane.y plane.x + (angular-size * 0.5) | mod tau / angular-size | floor)
              coord (rotate coord (* -1 angular-size $index))]
      expr))))

(defmacro- make-radiator [name coord & loop-body]
  ~(defn- ,name [$index rotate distance-field other-field count sample-from sample-to]
    (sugar (jlsl/do
      (var count count)
      (var angular-size (tau / count))
      (var angle (atan2 (. ,coord y) (. ,coord x) + (angular-size * 0.5) | mod tau / angular-size))
      (var base-index (floor angle))
      (var look-direction (angle | fract - 0.5 | sign))
      (var start-logical (sample-from * look-direction + base-index))
      (var end-logical (sample-to * look-direction + base-index))
      (var start (min start-logical end-logical))
      (var end (max start-logical end-logical))
      ,;loop-body))))

(make-radiator radial-distance-2d q
  (var nearest 1e20)
  (for (var i start) (<= i end) (++ i)
    (with [$index i q (rotate q (* -1 angular-size i))]
      (set nearest (min nearest distance-field))))
  nearest)

(make-radiator radial-other-2d q
  (var nearest 1e20)
  (var nearest-index 0)
  (for (var i start) (<= i end) (++ i)
    (with [$index i q (rotate q (* -1 angular-size i))]
      (var dist distance-field)
      (if (< dist nearest) (do
        (set nearest dist)
        (set nearest-index $index)))))
  (with [$index (mod nearest-index count) q (rotate q (* -1 angular-size $index))]
    other-field))

(make-radiator radial-distance-3d p
  (var nearest 1e20)
  (for (var i start) (<= i end) (++ i)
    (with [$index i p (rotate p (* -1 angular-size i))]
      (set nearest (min nearest distance-field))))
  nearest)

(make-radiator radial-other-3d p
  (var nearest 1e20)
  (var nearest-index 0)
  (for (var i start) (<= i end) (++ i)
    (with [$index i p (rotate p (* -1 angular-size i))]
      (var dist distance-field)
      (if (< dist nearest) (do
        (set nearest dist)
        (set nearest-index $index)))))
  (with [$index (mod nearest-index count) p (rotate p (* -1 angular-size $index))]
    other-field))

(defn- split-axis [axis]
  (sugar (case axis
    x [p.x p.yz]
    y [p.y p.zx]
    z [p.z p.xy]
    (errorf "unknown axis %q" (jlsl/show axis)))))

(defn- radial-aux [shape axis $index count oversample sample-from sample-to]
  (def size (typecheck count jlsl/type/float))
  (def [coord plane rotate radial-distance radial-other]
    (case (shape/type shape)
      jlsl/type/vec2 (do
        (assert (nil? axis) "cannot supply an axis with a 2D shape")
        [q q rotate radial-distance-2d radial-other-2d])
      jlsl/type/vec3 (do
        (def [this-axis other-axes] (split-axis axis))
        [p other-axes (fn [p angle] (rotate p axis angle)) radial-distance-3d radial-other-3d])))
  (def sample-from (typecheck (or sample-from 0) jlsl/type/float))
  (def sample-to (typecheck (or sample-to 1) jlsl/type/float))

  (if oversample
    (shape/map-fields shape (fn [name expr]
      (case name
        :distance (radial-distance $index rotate expr nil count sample-from sample-to)
        (radial-other $index rotate (shape/distance shape) expr count sample-from sample-to))))
    (shape/map shape (fn [expr]
      (simple-radial coord plane rotate $index expr count)))))

(defnamed radial [shape ?axis count :?oversample :?sample-from :?sample-to]
  ````
  TODOC
  ````
  (def $index (jlsl/variable/new "radial-index" jlsl/type/float))
  (radial-aux shape axis $index count oversample sample-from sample-to))

(defnamed radial* [?axis count get-shape :?oversample :?sample-from :?sample-to]
  ````
  TODOC
  ````
  (def $index (jlsl/variable/new "radial-index" jlsl/type/float))
  (def shape (get-shape $index))
  (radial-aux shape axis $index count oversample sample-from sample-to))

(defmacro radial:
  ````
  TODOC
  ````
  [shape $i & args]
  ~(,radial* ,;args (fn [,$i] ,shape)))