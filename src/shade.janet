(import ./glslisp/src/comp-state :as comp-state)
(import ./glslisp/src/index :as glslisp)
(import ./glsl-helpers)
(import ./globals)

(def debug? false)

(defn compile-function [{:name name :params params :body body :return-type return-type}]
  (string/format "%s %s(%s) {\n%s\n}" return-type name (string/join params ", ") body))

# TODO: this is duplicated
(defn- float [n]
  (if (int? n) (string n ".0") (string n)))

(defn compile-fragment-shader [expr camera]
  (def comp-state (comp-state/new glsl-helpers/functions))

  (when debug?
    (pp (:compile expr (:new-scope comp-state)))
    (pp (:surface expr (:new-scope comp-state))))
  (def distance-scope (:new-scope comp-state))
  (def color-scope (:new-scope comp-state))
  (def [distance-statements distance-expression] (:compile-distance distance-scope expr))

  (def [color-statements color-expression] (:compile-color color-scope expr))
  (def function-defs (string/join (map compile-function (comp-state :functions)) "\n"))

  # TODO: we should inspect (scope :free-variables) to determine which
  # of the builtins we actually need to compute when we're shading.
  # also, it will allow us to give better error messages if you do something
  # like use `normal` during a shape compilation

  (def distance-prep-statements @[])
  (each free-variable (keys (distance-scope :free-variables))
    (case free-variable
      globals/p nil
      globals/world-p (array/push distance-prep-statements "vec3 world_p = p;")
      (errorf "cannot use %s in a distance expression" (free-variable :name))))

  (def color-prep-statements @[])
  # this statement must come first so that the light intensity can see it
  (if (or ((color-scope :free-variables) globals/normal)
          ((color-scope :free-variables) globals/light-intensities))
    (array/push color-prep-statements "vec3 normal = calculate_normal(p);"))
  (each free-variable (keys (color-scope :free-variables))
    (case free-variable
      globals/p nil
      globals/camera nil
      globals/normal nil
      globals/world-p (array/push color-prep-statements "vec3 world_p = p;")
      globals/light-intensities (do
        # Array initialization syntax doesn't work on the Google
        # Pixel 6a, so we do this kinda dumb thing. Also a simple
        # for loop doesn't work on my mac. So I dunno.
        (array/push color-prep-statements "float light_intensities[3];")
        # A for loop would be obvious, but it doesn't work for some reason.
        (for i 0 3
          (array/push color-prep-statements
            (string `light_intensities[`i`] = cast_light(p + 2.0 * MINIMUM_HIT_DISTANCE * normal, lights[`i`].position, lights[`i`].radius);`))))
      (errorf "unexpected free variable %s" (free-variable :name))))

  (when debug?
    (print
      (string function-defs "\n"
        "float nearest_distance(vec3 p) {\n"
        (string/join distance-prep-statements "\n  ")"\n"
        (string/join distance-statements "\n  ")"\n"
        "return "distance-expression";\n}"))
    (print
      (string
        "vec3 nearest_color(vec3 p) {\n"
        (string/join color-prep-statements "\n  ") "\n"
        (string/join color-statements "\n  ") "\n"
        "return "color-expression";\n}")))

  (string `
#version 300 es
precision highp float;

const int MAX_STEPS = 256;
const float MINIMUM_HIT_DISTANCE = 0.1;
const float NORMAL_OFFSET = 0.005;
const float MAXIMUM_TRACE_DISTANCE = 8.0 * 1024.0;

struct Light {
  vec3 position;
  vec3 color;
  float radius;
};

// TODO: obviously these should be user-customizable,
// but it's kind of a whole thing and I'm working on
// it okay
const Light lights[3] = Light[3](
  Light(vec3(512.0, 512.0, 256.0), vec3(1.0), 2048.0),
  Light(vec3(0.0, 0.0, -512.0), vec3(0.0), 2048.0),
  Light(vec3(0.0, 0.0, 256.0), vec3(0.0), 2048.0)
);

vec3 calculate_normal(vec3 p);
float cast_light(vec3 destination, vec3 light, float radius);

`
function-defs
`
float nearest_distance(vec3 p) {
  `
  (string/join distance-prep-statements "\n  ") "\n  "
  (string/join distance-statements "\n  ")
  `
  return `distance-expression`;
}

vec3 nearest_color(vec3 p, vec3 camera) {
  `
  (string/join color-prep-statements "\n  ") "\n  "
  (string/join color-statements "\n  ")
  `
  return `color-expression`;
}

vec3 calculate_normal(vec3 p) {
  const vec3 step = vec3(NORMAL_OFFSET, 0.0, 0.0);

  return normalize(vec3(
    nearest_distance(p + step.xyy) - nearest_distance(p - step.xyy),
    nearest_distance(p + step.yxy) - nearest_distance(p - step.yxy),
    nearest_distance(p + step.yyx) - nearest_distance(p - step.yyx)
  ));
}

float cast_light(vec3 p, vec3 light, float radius) {
  vec3 direction = normalize(light - p);
  float light_distance = distance(light, p);

  float light_brightness = 1.0 - (light_distance / radius);
  if (light_brightness <= 0.0) {
    return 0.0;
  }

  float in_light = 1.0;
  float sharpness = 16.0;

  float last_distance = 1e20;
  // TODO: It would make more sense to start at
  // the light and cast towards the point, so that
  // we don't have to worry about this nonsense.
  float progress = MINIMUM_HIT_DISTANCE;
  for (int i = 0; i < MAX_STEPS; i++) {
    if (progress > light_distance) {
      return in_light * light_brightness;
    }

    float distance = nearest_distance(p + progress * direction);

    if (distance < MINIMUM_HIT_DISTANCE) {
      // we hit something
      return 0.0;
    }

    float intersect_offset = distance * distance / (2.0 * last_distance);
    float intersect_distance = sqrt(distance * distance - intersect_offset * intersect_offset);
    if (distance < last_distance) {
      in_light = min(in_light, sharpness * intersect_distance / max(0.0, progress - intersect_offset));
    }
    progress += distance;
    last_distance = distance;
  }
  // we never reached the light
  return 0.0;
}

vec3 march(vec3 ray_origin, vec3 ray_direction, out int steps) {
  float distance = 0.0;

  for (steps = 0; steps < MAX_STEPS; steps++) {
    vec3 p = ray_origin + distance * ray_direction;

    float nearest = nearest_distance(p);

    // TODO: this attenuation only works when we're
    // using march to render from the camera's point
    // of view, so we can't use the march function
    // as-is to render reflections. I don't know if
    // it's worth having.
    // if (nearest < distance * MINIMUM_HIT_DISTANCE * 0.01) {
    if (nearest < MINIMUM_HIT_DISTANCE || distance > MAXIMUM_TRACE_DISTANCE) {
      return p + nearest * ray_direction;
    }

    distance += nearest;
  }
  return ray_origin + distance * ray_direction;
}

mat4 view_matrix(vec3 eye, vec3 target, vec3 up) {
  vec3 f = normalize(target - eye);
  vec3 s = normalize(cross(f, up));
  vec3 u = cross(s, f);
  return mat4(
      vec4(s, 0.0),
      vec4(f, 0.0),
      vec4(u, 0.0),
      vec4(0.0, 0.0, 0.0, 1.0)
  );
}

out vec4 frag_color;

const float PI = 3.14159265359;
const float DEG_TO_RAD = PI / 180.0;

vec3 ray_dir(float fov, vec2 size, vec2 pos) {
  vec2 xy = pos - size * 0.5;

  float cot_half_fov = tan((90.0 - fov * 0.5) * DEG_TO_RAD);
  float z = size.y * 0.5 * cot_half_fov;

  return normalize(vec3(xy, -z));
}

mat3 rotate_xy(vec2 angle) {
  vec2 c = cos(angle);
  vec2 s = sin(angle);

  return mat3(
    c.y      ,  0.0, -s.y,
    s.y * s.x,  c.x,  c.y * s.x,
    s.y * c.x, -s.x,  c.y * c.x
  );
}

void main() {
  const float gamma = 2.2;
  const vec2 resolution = vec2(1024.0, 1024.0);

  vec2 rotation = vec2(`(float (camera :x))`, `(float (camera :y))`);
  mat3 camera_matrix = rotate_xy(rotation);

  vec3 dir = ray_dir(45.0, resolution, gl_FragCoord.xy);
  vec3 eye = vec3(0.0, 0.0, `(float (* 256 (camera :zoom)))`);
  dir = camera_matrix * dir;
  eye = camera_matrix * eye;

  const vec3 fog_color = vec3(0.15);
  const vec3 abort_color = vec3(1.0, 0.0, 1.0);

  // TODO: we only need the steps out parameter when
  // we're rendering the debug view. Should try to
  // see if there's any performance difference between
  // an out parameter and a local variable.
  int steps;
  vec3 hit = march(eye, dir, steps);

  vec3 color = nearest_color(hit, eye);
  float depth = length(hit - eye);
  float attenuation = depth / MAXIMUM_TRACE_DISTANCE;
  color = mix(color, fog_color, clamp(attenuation * attenuation, 0.0, 1.0));

  // This is a view for debugging convergence, but it also just...
  // looks really cool on its own:
  // if (steps == MAX_STEPS) {
  //   color = abort_color;
  // } else {
  //   color = vec3(float(steps) / float(MAX_STEPS));
  // }

  // This is a good view for debugging overshooting.
  // float distance = nearest_distance(hit);
  // float overshoot = max(-distance, 0.0) / MINIMUM_HIT_DISTANCE;
  // float undershoot = max(distance, 0.0) / MINIMUM_HIT_DISTANCE;
  // color = vec3(overshoot, 1.0 - undershoot - overshoot, 0.0);

  frag_color = vec4(pow(color, vec3(1.0 / gamma)), 1.0);
}
`))

# surely I can do better
(defn is-good-value? [value]
  (and (struct? value)
       (not (nil? (value :compile)))))

(fiber/new (fn []
  (def context (new-gl-context "#render-target"))
  (while true
    (let [[expr camera] (yield)]
      (if (is-good-value? expr)
        (try
          (do
            (set-fragment-shader context
              (compile-fragment-shader expr camera))
            (render context))
          ([err fiber]
            (debug/stacktrace fiber err "")))
        (eprint "cannot compile " expr))))))
