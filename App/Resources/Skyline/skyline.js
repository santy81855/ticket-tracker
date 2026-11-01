"use strict";

(() => {
  const canvas = document.querySelector("#universe");
  const diagnostics = { status: "loading", error: null, frames: 0, paused: true, time: 0 };
  window.__skyline = diagnostics;

  function notify() {
    window.webkit?.messageHandlers?.skyline?.postMessage({
      status: diagnostics.status, error: diagnostics.error,
    });
  }

  function fail(error) {
    diagnostics.status = "error";
    diagnostics.error = String(error.message || error);
    notify();
  }

  addEventListener("error", event => fail(event.error || event.message));
  addEventListener("unhandledrejection", event => fail(event.reason));

  try {
    const gl = canvas.getContext("webgl2", {
      alpha: false, antialias: false, depth: false, stencil: false,
      powerPreference: "high-performance", preserveDrawingBuffer: false,
    });
    if (!gl) throw new Error("Skyline requires WebGL 2, which is unavailable on this Mac.");
    if (!gl.getExtension("EXT_color_buffer_float")) {
      throw new Error("Floating-point render targets are unavailable on this Mac.");
    }

    const vertex = `#version 300 es
      precision highp float;
      out vec2 uv;
      void main() {
        vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
        uv = p;
        gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
      }`;

    const sceneSource = `#version 300 es
      precision highp float;
      in vec2 uv;
      out vec4 result;
      uniform vec2 resolution;
      uniform float time;
      uniform float breath;

      const float STREET = -0.33;
      const float CURB = -0.348;

      float hash(vec2 p) {
        vec3 q = fract(vec3(p.xyx) * 0.1031);
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
      }
      float noise(vec2 p) {
        vec2 i = floor(p), f = fract(p);
        f = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x),
          mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
      }
      float fbm(vec2 p) {
        float n = 0.5 * noise(p);
        p = mat2(1.6, -1.2, 1.2, 1.6) * p;
        n += 0.25 * noise(p + 8.7);
        p = mat2(1.6, -1.2, 1.2, 1.6) * p;
        n += 0.125 * noise(p + 19.3);
        return n / 0.875;
      }

      const vec3 CITY_GLOW = vec3(0.34, 0.15, 0.17);
      const vec3 LAMP = vec3(1.0, 0.72, 0.42);

      vec3 sky(vec2 p, float t) {
        float h = p.y - STREET;
        vec3 c = mix(vec3(0.035, 0.030, 0.085), vec3(0.005, 0.008, 0.030), smoothstep(0.1, 0.85, h));
        c += CITY_GLOW * exp(-h * 5.0);
        vec2 g = p * 150.0;
        vec2 id = floor(g), f = fract(g) - 0.5;
        float hs = hash(id);
        if (hs > 0.972) {
          f -= (vec2(hash(id + 2.0), hash(id + 5.0)) - 0.5) * 0.6;
          float s = exp(-dot(f, f) * 70.0);
          c += vec3(0.8, 0.85, 1.0) * s * (0.45 + 0.55 * sin(t * (1.0 + 2.0 * hash(id + 9.0)) + hs * 90.0)) * smoothstep(0.18, 0.6, h);
        }
        vec2 m = p - vec2(0.50, 0.30);
        float d = length(m), R = 0.034;
        float maria = fbm(m * 85.0 + 3.0);
        vec3 moon = vec3(1.0, 0.95, 0.84) * (1.9 - 0.7 * smoothstep(0.45, 0.72, maria));
        moon *= 0.7 + 0.3 * sqrt(max(0.0, 1.0 - d * d / (R * R)));
        c = mix(c, moon, smoothstep(R, R - 0.0018, d));
        c += vec3(0.55, 0.62, 0.85) * (exp(-d * 24.0) * 0.20 + exp(-d * 6.0) * 0.05) * (1.0 + 0.9 * breath);
        float cl = fbm(vec2(p.x * 2.0 + t * 0.006, p.y * 6.5 - t * 0.002));
        cl = smoothstep(0.52, 0.85, cl) * smoothstep(0.08, 0.22, h) * smoothstep(0.8, 0.4, h);
        vec3 cloud = vec3(0.07, 0.06, 0.11) + CITY_GLOW * 0.4 * exp(-h * 3.0) + vec3(0.6, 0.65, 0.8) * exp(-d * 7.0) * 0.5;
        c = mix(c, cloud, cl * 0.6);
        // An airliner crosses now and then with a strobing wingtip.
        float cycle = floor(t / 70.0), ph = fract(t / 70.0);
        vec2 plane = vec2(-1.1 + ph * 3.2, 0.18 + 0.2 * hash(vec2(cycle, 4.0)) + ph * 0.03);
        float pd = length(p - plane);
        float strobe = step(0.93, fract(t * 0.9));
        c += vec3(1.0, 0.15, 0.1) * exp(-pd * pd / 2e-6) * (0.6 + 0.4 * sin(t * 6.0)) * 2.0;
        c += vec3(1.0) * exp(-pd * pd / 4e-6) * strobe * 4.0;
        return c;
      }

      struct Building { float top; float roof; float left; float width; float id; float kind; };

      Building building(float x, float cw, float seed, float hmin, float hmax, float px) {
        Building b = Building(-1.0, 0.0, 0.0, 0.0, 0.0, 0.0);
        for (int k = 0; k < 2; k++) {
          float fk = float(k);
          float w = cw * (1.0 + 0.41 * fk);
          float off = fk * 0.37;
          float cx = x / w + off;
          float id = floor(cx), f = fract(cx);
          vec2 key = vec2(id, seed + fk * 17.0);
          float inset = 0.03 + 0.14 * hash(key + 5.0);
          if (f < inset || f > 1.0 - inset) continue;
          float roof = hmin + (hmax - hmin) * pow(hash(key), 1.7);
          float kind = hash(key + 9.0);
          float bw = w * (1.0 - 2.0 * inset);
          float ff = (f - inset) / (1.0 - 2.0 * inset);
          float top = roof;
          if (kind > 0.86 && roof > hmin + (hmax - hmin) * 0.45) {
            float dx = abs(ff - 0.5) * bw;
            top += step(dx, px * 1.3) * 0.09 * (hmax - hmin) + step(dx, bw * 0.12) * 0.035 * (hmax - hmin);
          } else if (kind > 0.68) {
            if (abs(ff - 0.5) > 0.3) { top -= 0.18 * roof; roof = top; }
          } else if (kind > 0.58) {
            top += (0.5 - abs(ff - 0.5)) * bw * 0.5;
          }
          if (top > b.top) {
            b = Building(top, roof, (id - off + inset) * w, bw, id + fk * 1013.0 + seed * 7.0, kind);
          }
        }
        return b;
      }

      vec3 windows(Building b, vec2 q, vec2 cell, float px, float t) {
        float u = q.x - b.left, v = q.y - STREET;
        if (v > b.roof - cell.y * 0.7 || u < cell.x * 0.5 || u > b.width - cell.x * 0.5 || v < cell.y * 1.4) return vec3(0);
        vec2 g = vec2(u - cell.x * 0.5, v) / cell;
        vec2 wid = floor(g), wf = fract(g);
        float occ = 0.1 + 0.45 * hash(vec2(b.id, 3.1));
        float period = 18.0 + 60.0 * hash(wid.yx + b.id);
        float phase = floor(t / period + hash(wid + b.id * 1.37) * 7.0);
        float lit = step(hash(wid * 1.7 + b.id + phase * 3.1), occ);
        float temp = hash(vec2(b.id, 8.8));
        vec3 col = temp < 0.55 ? vec3(1.0, 0.68, 0.38) : temp < 0.85 ? vec3(0.76, 0.87, 1.0) : vec3(0.5, 1.0, 0.88);
        col *= 0.45 + 0.65 * hash(wid + b.id * 3.3);
        // A few lit windows flicker blue with a TV.
        if (hash(wid + b.id * 5.1) > 0.96) col = vec3(0.35, 0.5, 1.0) * (0.6 + 0.4 * noise(vec2(t * 6.0, wid.x)));
        float shape = smoothstep(0.16, 0.24, wf.x) * smoothstep(0.84, 0.76, wf.x) * smoothstep(0.2, 0.3, wf.y) * smoothstep(0.82, 0.72, wf.y);
        float detail = clamp((cell.x / px - 1.5) / 2.5, 0.0, 1.0);
        return col * lit * mix(0.33, shape, detail);
      }

      vec3 layer(vec3 c, vec2 p, float pan, float cw, float seed, float hmin, float hmax, vec2 cell, vec3 base, float haze, bool neon, float t, float px) {
        vec2 q = vec2(p.x + pan, p.y);
        Building b = building(q.x, cw, seed, hmin, hmax, px);
        float v = p.y - STREET;
        float cx = b.left + b.width * 0.5;
        if (b.top > 0.0 && v < b.top) {
          float ff = (q.x - b.left) / b.width;
          vec3 f = base * (0.75 + 0.5 * hash(vec2(b.id, 1.1))) * (0.8 + 0.45 * ff);
          f += CITY_GLOW * 0.10 * exp(-v * 10.0);
          f += vec3(0.5, 0.55, 0.75) * 0.05 * smoothstep(b.width - px * 2.5, b.width, q.x - b.left);
          f += windows(b, q, cell, px, t) * (1.1 + 0.3 * breath);
          if (neon && b.kind > 0.45 && b.kind < 0.62) {
            vec2 sc = vec2(b.left + b.width * (0.12 + 0.76 * step(0.53, b.kind)), STREET + b.roof * 0.55);
            vec2 hs = vec2(0.0055, b.roof * 0.22);
            vec2 dq = abs(q - sc) - hs;
            float sd = length(max(dq, 0.0)) + min(max(dq.x, dq.y), 0.0);
            float pick = hash(vec2(b.id, 2.2));
            vec3 nc = pick < 0.4 ? vec3(1.0, 0.18, 0.62) : pick < 0.75 ? vec3(0.15, 0.9, 1.0) : vec3(1.0, 0.55, 0.12);
            float flick = 1.0 - 0.85 * step(0.93, noise(vec2(t * 7.0, b.id)));
            float letters = step(0.28, fract((q.y - sc.y) / 0.011));
            f = mix(f, nc * 0.06, step(sd, 0.0015));
            f += nc * (step(sd, 0.0) * letters * 2.4 + exp(-max(sd, 0.0) * 140.0) * 0.35) * flick;
          }
          vec3 hz = vec3(0.10, 0.06, 0.13) + CITY_GLOW * 0.45 * exp(-v * 6.0);
          c = mix(f, hz, haze);
        }
        // Red aviation beacons on the tallest roofs.
        if (b.top > hmin + (hmax - hmin) * 0.55) {
          float d = length(vec2(q.x - cx, v - b.top - 0.002));
          float blink = smoothstep(0.0, 0.15, sin(t * 1.6 + b.id) - 0.2);
          c += vec3(1.0, 0.08, 0.05) * (exp(-d * d / 3e-6) * 3.0 + exp(-d * 90.0) * 0.12) * blink * (1.0 - haze * 0.6);
        }
        return c;
      }

      vec3 car(vec3 c, vec2 p, float road, float yb, float dir, float speed, float scale, float seed, float t, float px) {
        float cell = 0.42;
        float xx = p.x + road - dir * speed * t;
        float id0 = floor(xx / cell);
        vec3 light = vec3(0);
        for (int j = -1; j <= 1; j++) {
          float id = id0 + float(j);
          vec2 key = vec2(id, seed);
          if (hash(key) < 0.3) continue;
          float kind = hash(key + 3.0);
          float L = (kind > 0.93 ? 0.17 : 0.062 + 0.02 * hash(key + 1.0)) * scale;
          float H = (kind > 0.93 ? 1.55 : kind > 0.8 ? 1.2 : 1.0) * scale;
          float lx = xx - id * cell - hash(key + 2.0) * (cell - L);
          float s = dir > 0.0 ? lx : L - lx;
          float ly = p.y - yb;
          // Headlight beam and wet-road reflections.
          float dl = s - L;
          if (dl > 0.0) {
            float spread = 0.004 * H + dl * 0.16;
            light += LAMP * 0.3 * exp(-dl * 18.0) * exp(-pow((ly - 0.011 * H + dl * 0.1) / spread, 2.0));
          }
          vec2 head = vec2(L - 0.0015, 0.012 * H), tail = vec2(0.0015, 0.012 * H);
          float hd = length(vec2(s, ly) - head), td = length(vec2(s, ly) - tail);
          light += vec3(1.0, 0.92, 0.8) * (exp(-hd * hd / 4e-6) * 4.0 + exp(-hd * 80.0) * 0.18);
          light += vec3(1.0, 0.06, 0.04) * (exp(-td * td / 3e-6) * 2.5 + exp(-td * 120.0) * 0.12);
          if (ly < 0.0) {
            float fall = exp(ly * 45.0);
            light += vec3(1.0, 0.9, 0.75) * exp(-pow((s - head.x) / 0.004, 2.0)) * fall * 0.35;
            light += vec3(1.0, 0.1, 0.06) * exp(-pow((s - tail.x) / 0.004, 2.0)) * fall * 0.25;
          }
          if (lx < 0.0 || lx > L || ly < 0.0 || ly > 0.032 * H) continue;
          vec3 paint = kind > 0.93 ? vec3(0.06, 0.09, 0.16)
            : kind > 0.8 ? vec3(0.07, 0.07, 0.075)
            : kind > 0.68 ? vec3(0.42, 0.28, 0.02)
            : kind > 0.52 ? vec3(0.22, 0.015, 0.02)
            : kind > 0.38 ? vec3(0.02, 0.05, 0.16)
            : kind > 0.26 ? vec3(0.17, 0.17, 0.18)
            : kind > 0.14 ? vec3(0.01, 0.10, 0.09)
            : vec3(0.025, 0.025, 0.03);
          vec2 bc = vec2(L * 0.5, 0.0115 * H);
          vec2 bq = abs(vec2(s, ly) - bc) - vec2(L * 0.5 - 0.003, 0.0055 * H - 0.0015);
          float body = length(max(bq, 0.0)) + min(max(bq.x, bq.y), 0.0) - 0.003 * scale;
          float cabinLo = 0.017 * H, cabinHi = (kind > 0.8 ? 0.03 : 0.026) * H;
          float rise = (ly - cabinLo) / (cabinHi - cabinLo);
          float front = kind > 0.8 ? 0.94 : 0.72 - 0.16 * rise;
          float rear = kind > 0.8 ? 0.04 : 0.24 + 0.08 * rise;
          bool cabin = ly > cabinLo - 0.001 && ly < cabinHi && s > L * rear && s < L * front;
          vec3 col = c;
          if (cabin) {
            bool glass = ly < cabinHi - 0.0015 && s > L * rear + 0.002 && s < L * front - 0.002;
            float lit = kind > 0.93 ? step(0.5, fract(s / 0.012)) * 0.9 : 0.0;
            col = glass ? vec3(0.03, 0.04, 0.06) + vec3(0.25, 0.3, 0.4) * 0.15 * (1.0 - rise) + vec3(1.0, 0.8, 0.5) * lit * 0.35 : paint * 0.9;
          }
          if (body < 0.0) {
            col = paint * (0.45 + 0.55 * smoothstep(0.004 * H, 0.016 * H, ly));
            col += vec3(0.7, 0.75, 0.9) * exp(-abs(ly - 0.0165 * H) * 900.0) * 0.08;
          }
          for (int w = 0; w < 2; w++) {
            float wx = L * (w == 0 ? 0.19 : 0.81);
            float wd = length(vec2(s - wx, ly - 0.0052 * scale));
            if (wd < 0.0052 * scale) col = mix(vec3(0.008), vec3(0.12, 0.12, 0.13), step(wd, 0.0022 * scale));
          }
          c = col;
        }
        return c + light;
      }

      void main() {
        vec2 p = (gl_FragCoord.xy - resolution * 0.5) / resolution.y;
        float t = time;
        float px = 1.0 / resolution.y;
        vec3 c = sky(p, t);
        c = layer(c, p, t * 0.0016, 0.042, 1.0, 0.12, 0.34, vec2(0.0034, 0.0052), vec3(0.04, 0.038, 0.08), 0.5, false, t, px);
        c = layer(c, p, t * 0.0034, 0.068, 2.0, 0.07, 0.52, vec2(0.0058, 0.0088), vec3(0.020, 0.022, 0.048), 0.22, false, t, px);
        c = layer(c, p, t * 0.0062, 0.115, 3.0, 0.035, 0.27, vec2(0.0105, 0.0155), vec3(0.009, 0.010, 0.022), 0.04, true, t, px);
        float road = t * 0.0075;
        float rx = p.x + road;
        float lampX = (floor(rx / 0.27) + 0.5) * 0.27;
        float ldx = rx - lampX;
        vec2 head = vec2(ldx - 0.012, p.y - STREET - 0.088);
        float hd = length(head);
        if (p.y < STREET) {
          float y = p.y;
          if (y > CURB) {
            c = vec3(0.035, 0.032, 0.04) + LAMP * 0.22 * exp(-ldx * ldx / 0.0012) + CITY_GLOW * 0.03;
            c *= 0.85 + 0.15 * step(0.5, fract(rx / 0.03));
            c += vec3(0.08, 0.07, 0.08) * smoothstep(CURB + 0.003, CURB, y);
          } else {
            float depth = CURB - y;
            vec3 asphalt = vec3(0.011, 0.011, 0.016) * (0.8 + 0.4 * noise(vec2(rx * 400.0, y * 400.0)));
            float wet = 0.6 + 0.4 * fbm(vec2(rx * 9.0, y * 40.0));
            c = asphalt + CITY_GLOW * 0.022 * wet;
            // Mirror-like streaks under the street lamps and lit windows.
            c += LAMP * exp(-pow((ldx - 0.012) / 0.006, 2.0)) * exp(-depth * 9.0) * 0.35 * wet;
            c += vec3(0.6, 0.45, 0.4) * 0.05 * exp(-depth * 6.0) * noise(vec2(rx * 60.0, 1.0)) * wet;
            float dash = step(0.5, fract(rx / 0.07)) * smoothstep(0.0016, 0.0008, abs(y + 0.425));
            c += vec3(0.45, 0.42, 0.32) * dash * 0.35;
            c += LAMP * 0.05 * exp(-ldx * ldx / 0.002) * exp(-depth * 12.0);
          }
        }
        // Street lamps stand in front of the closest towers.
        if (abs(ldx) < 0.0011 && p.y > STREET - 0.004 && p.y < STREET + 0.09) c = vec3(0.02, 0.02, 0.025);
        if (abs(p.y - STREET - 0.09) < 0.0011 && ldx > -0.001 && ldx < 0.016) c = vec3(0.02, 0.02, 0.025);
        float below = STREET + 0.088 - p.y;
        if (below > 0.0) c += LAMP * 0.07 * exp(-pow((ldx - 0.012) / (0.002 + below * 0.32), 2.0)) * smoothstep(0.0, 0.01, below);
        c += LAMP * (exp(-hd * hd / 1e-5) * 3.5 + exp(-hd * 30.0) * 0.1) * (1.0 + 0.2 * breath);
        c = car(c, p, road, -0.392, -1.0, 0.055, 0.9, 11.0, t, px);
        c = car(c, p, road, -0.392, -1.0, 0.082, 0.9, 23.0, t, px);
        c = car(c, p, road, -0.468, 1.0, 0.065, 1.08, 37.0, t, px);
        c = car(c, p, road, -0.468, 1.0, 0.097, 1.08, 51.0, t, px);
        result = vec4(c, 1.0);
      }`;

    const blurSource = `#version 300 es
      precision highp float;
      in vec2 uv;
      out vec4 result;
      uniform sampler2D image;
      uniform vec2 axis;
      uniform bool extract;
      void main() {
        vec3 c = texture(image, uv).rgb * 0.227027;
        c += texture(image, uv + axis * 1.384615).rgb * 0.316216;
        c += texture(image, uv - axis * 1.384615).rgb * 0.316216;
        c += texture(image, uv + axis * 3.230769).rgb * 0.070270;
        c += texture(image, uv - axis * 3.230769).rgb * 0.070270;
        if (extract) c *= smoothstep(0.50, 1.6, max(c.r, max(c.g, c.b)));
        result = vec4(c, 1.0);
      }`;

    const compositeSource = `#version 300 es
      precision highp float;
      in vec2 uv;
      out vec4 result;
      uniform sampler2D image;
      uniform sampler2D bloom;
      uniform float exposure;
      uniform float strength;
      vec3 tonemap(vec3 x) {
        return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);
      }
      void main() {
        vec3 c = texture(image, uv).rgb * exposure;
        c += texture(bloom, uv).rgb * 0.32 * sqrt(exposure);
        vec2 v = uv - 0.5;
        c *= 1.0 - 0.42 * dot(v, v);
        c = pow(tonemap(c), vec3(1.0 / 2.2));
        result = vec4(c * strength, 1.0);
      }`;

    function program(fragment) {
      function shader(type, source) {
        const handle = gl.createShader(type);
        if (!handle) throw new Error("Could not allocate a graphics shader.");
        gl.shaderSource(handle, source);
        gl.compileShader(handle);
        if (!gl.getShaderParameter(handle, gl.COMPILE_STATUS)) {
          const message = gl.getShaderInfoLog(handle);
          gl.deleteShader(handle);
          throw new Error(message || "Shader compilation failed.");
        }
        return handle;
      }
      const handle = gl.createProgram();
      if (!handle) throw new Error("Could not allocate a graphics program.");
      const v = shader(gl.VERTEX_SHADER, vertex);
      const f = shader(gl.FRAGMENT_SHADER, fragment);
      gl.attachShader(handle, v);
      gl.attachShader(handle, f);
      gl.linkProgram(handle);
      gl.deleteShader(v);
      gl.deleteShader(f);
      if (!gl.getProgramParameter(handle, gl.LINK_STATUS)) {
        const message = gl.getProgramInfoLog(handle);
        gl.deleteProgram(handle);
        throw new Error(message || "Graphics program linking failed.");
      }
      return { handle, uniform: name => gl.getUniformLocation(handle, name) };
    }

    const scene = program(sceneSource);
    const blur = program(blurSource);
    const composite = program(compositeSource);
    let targets = [];
    let width = 0, height = 0, bloomWidth = 0, bloomHeight = 0;
    let elapsed = 0, previousTime = 0, previousDraw = 0, animation = 0;
    let paused = true;

    function target(w, h) {
      const texture = gl.createTexture();
      const framebuffer = gl.createFramebuffer();
      if (!texture || !framebuffer) throw new Error("Could not allocate a render target.");
      gl.bindTexture(gl.TEXTURE_2D, texture);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.HALF_FLOAT, null);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, texture, 0);
      if (gl.checkFramebufferStatus(gl.FRAMEBUFFER) !== gl.FRAMEBUFFER_COMPLETE) {
        throw new Error("The browser could not create a complete floating-point framebuffer.");
      }
      return { texture, framebuffer };
    }

    function resize() {
      const scale = Math.min(1, Math.sqrt(1000000 / (innerWidth * innerHeight)));
      const w = Math.max(1, Math.round(innerWidth * scale));
      const h = Math.max(1, Math.round(innerHeight * scale));
      if (width === w && height === h) return;
      for (const old of targets) {
        gl.deleteTexture(old.texture);
        gl.deleteFramebuffer(old.framebuffer);
      }
      width = canvas.width = w;
      height = canvas.height = h;
      bloomWidth = Math.max(1, Math.round(w / 4));
      bloomHeight = Math.max(1, Math.round(h / 4));
      targets = [target(w, h), target(bloomWidth, bloomHeight), target(bloomWidth, bloomHeight)];
    }

    function bindTexture(texture, slot) {
      gl.activeTexture(gl.TEXTURE0 + slot);
      gl.bindTexture(gl.TEXTURE_2D, texture);
    }

    function blurPass(source, destination, x, y, extract) {
      gl.bindFramebuffer(gl.FRAMEBUFFER, destination.framebuffer);
      gl.viewport(0, 0, bloomWidth, bloomHeight);
      gl.useProgram(blur.handle);
      bindTexture(source.texture, 0);
      gl.uniform1i(blur.uniform("image"), 0);
      gl.uniform2f(blur.uniform("axis"), x, y);
      gl.uniform1i(blur.uniform("extract"), extract ? 1 : 0);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }

    function draw(time) {
      resize();
      const [full, a, b] = targets;
      gl.bindFramebuffer(gl.FRAMEBUFFER, full.framebuffer);
      gl.viewport(0, 0, width, height);
      gl.useProgram(scene.handle);
      gl.uniform2f(scene.uniform("resolution"), width, height);
      gl.uniform1f(scene.uniform("time"), time);
      gl.uniform1f(scene.uniform("breath"), breathLevel());
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      blurPass(full, a, 0.6 / width, 0.6 / height, true);
      blurPass(a, b, 1.5 / bloomWidth, 0, false);
      blurPass(b, a, 0, 1.5 / bloomHeight, false);
      blurPass(a, b, 2.6 / bloomWidth, 0, false);
      blurPass(b, a, 0, 2.6 / bloomHeight, false);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      gl.viewport(0, 0, width, height);
      gl.useProgram(composite.handle);
      bindTexture(full.texture, 0);
      bindTexture(a.texture, 1);
      gl.uniform1i(composite.uniform("image"), 0);
      gl.uniform1i(composite.uniform("bloom"), 1);
      gl.uniform1f(composite.uniform("exposure"), 0.95 + 0.08 * breathLevel());
      gl.uniform1f(composite.uniform("strength"), 0.62);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      const error = gl.getError();
      if (error !== gl.NO_ERROR) throw new Error(`WebGL render error: ${error}`);
      diagnostics.frames++;
      diagnostics.time = time;
    }

    // Breathing guide: the city lights and moon glow brighter for 5s (inhale), then dims for 5s.
    let breathing = false, breathAmount = 0, breathStart = 0;
    function breathLevel() {
      if (breathAmount <= 0) return 0;
      return breathAmount * (1 - Math.cos((elapsed - breathStart) * Math.PI / 5)) / 2;
    }
    function easeBreathing(dt) {
      const target = breathing ? 1 : 0;
      breathAmount += Math.sign(target - breathAmount) * Math.min(Math.abs(target - breathAmount), dt / 1.5);
    }

    function frame(timestamp) {
      animation = 0;
      if (paused || document.hidden || diagnostics.status === "error") return;
      const dt = previousTime ? Math.min((timestamp - previousTime) / 1000, 0.1) : 0;
      previousTime = timestamp;
      elapsed += dt;
      easeBreathing(dt);
      if (timestamp - previousDraw >= 1000 / 30) {
        try { draw(elapsed); } catch (error) { fail(error); return; }
        previousDraw = timestamp;
      }
      animation = requestAnimationFrame(frame);
    }

    function start() {
      cancelAnimationFrame(animation);
      previousTime = 0;
      if (!paused && !document.hidden && diagnostics.status === "ready") {
        animation = requestAnimationFrame(frame);
      }
    }

    diagnostics.setNativeMotion = enabled => {
      paused = !enabled;
      diagnostics.paused = paused;
      start();
    };
    diagnostics.setBreathing = enabled => {
      if (enabled && !breathing && breathAmount <= 0) breathStart = elapsed;
      breathing = Boolean(enabled);
      diagnostics.breathing = breathing;
    };
    diagnostics.stop = () => {
      paused = diagnostics.paused = true;
      cancelAnimationFrame(animation);
      for (const old of targets) {
        gl.deleteTexture(old.texture);
        gl.deleteFramebuffer(old.framebuffer);
      }
      targets = [];
      for (const pipeline of [scene, blur, composite]) gl.deleteProgram(pipeline.handle);
      gl.getExtension("WEBGL_lose_context")?.loseContext();
    };
    // Read pixels in the same turn as drawing, before WebGL discards its drawing buffer.
    diagnostics.captureFrame = time => {
      if (!paused) throw new Error("Pause native animation before deterministic capture.");
      elapsed = time;
      draw(time);
      const pixels = new Uint8Array(width * height * 4);
      gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
      let signature = 2166136261, litPixels = 0;
      for (let i = 0; i < pixels.length; i += 4) {
        if (pixels[i] + pixels[i + 1] + pixels[i + 2] > 45) litPixels++;
        signature = Math.imul(signature ^ pixels[i], 16777619);
        signature = Math.imul(signature ^ pixels[i + 1], 16777619);
        signature = Math.imul(signature ^ pixels[i + 2], 16777619);
      }
      return { signature: signature >>> 0, litPixels, width, height };
    };
    document.addEventListener("visibilitychange", start);
    addEventListener("resize", () => {
      try { draw(elapsed); } catch (error) { fail(error); }
    });
    canvas.addEventListener("webglcontextlost", event => {
      event.preventDefault();
      cancelAnimationFrame(animation);
      fail(new Error("The graphics context was lost. Select another theme and return to Skyline."));
    });
    draw(0);
    diagnostics.status = "ready";
    notify();
  } catch (error) {
    fail(error);
  }
})();
