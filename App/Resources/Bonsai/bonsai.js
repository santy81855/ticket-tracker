"use strict";

(() => {
  const canvas = document.querySelector("#universe");
  const diagnostics = { status: "loading", error: null, frames: 0, paused: true, time: 0 };
  window.__bonsai = diagnostics;

  function notify() {
    window.webkit?.messageHandlers?.bonsai?.postMessage({
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
    if (!gl) throw new Error("Bonsai requires WebGL 2, which is unavailable on this Mac.");
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
      uniform float season;


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

      const float PI = 3.14159265;
      float S;          // season 0 spring .. 3 winter
      float FALL;       // fraction of leaves dropped
      float WINTER;     // snow amount
      float BLOOM;      // blossom amount
      vec3 LIGHT;       // window light color * intensity
      float T;

      mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }

      float sdBox(vec2 p, vec2 b) {
        vec2 d = abs(p) - b;
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
      }

      float smin(float a, float b, float k) {
        float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
        return mix(b, a, h) - k * h * (1.0 - h);
      }

      // Outdoor branches casting soft moving shadows on the paper screen.
      float outsideShadow(vec2 p) {
        vec2 q = p * vec2(2.6, 3.2) + vec2(0.04 * sin(T * 0.23), 0.03 * sin(T * 0.31 + 1.0));
        float leaves = smoothstep(0.52, 0.66, fbm(q * 2.0 + vec2(3.0, 1.0)));
        float limbs = smoothstep(0.03, 0.0, abs(q.y - 0.35 * q.x - 0.7 + 0.1 * sin(q.x * 3.0)) - 0.015 * (2.0 - q.x));
        leaves *= mix(1.0, 0.25, FALL) * smoothstep(-0.3, 0.3, p.y + p.x * 0.4);
        return clamp(leaves * 0.55 + limbs * 0.4, 0.0, 1.0);
      }

      vec3 room(vec2 p, float R) {
        vec3 amb = LIGHT * 0.04 + vec3(0.008, 0.007, 0.006);
        // Plaster wall on the left.
        float n = fbm(p * 30.0) * 0.6 + fbm(p * 140.0) * 0.4;
        vec3 c = vec3(0.55, 0.47, 0.38) * (0.85 + 0.25 * n) * (amb * 1.4 + LIGHT * 0.08 * exp(-length(p - vec2(-0.1, 0.1)) * 2.5));
        // Shoji screen: glowing washi paper behind a softly defocused kumiko lattice.
        float sx = -0.18;
        if (p.x > sx && p.y > -0.4) {
          vec2 q = p - vec2(sx, -0.4);
          float glow = 0.8 + 0.35 * smoothstep(-0.2, 0.9, q.y) + 0.15 * smoothstep(0.0, 1.0, q.x);
          float fiber = 0.92 + 0.08 * fbm(vec2(p.x * 60.0, p.y * 18.0)) + 0.04 * noise(p * 400.0);
          float sh = outsideShadow(p);
          vec3 paper = LIGHT * vec3(1.0, 0.94, 0.84) * glow * fiber * (1.0 - 0.55 * sh);
          if (WINTER > 0.0) {
            float flakes = 0.0;
            for (int i = 0; i < 2; i++) {
              float sc = 16.0 + float(i) * 11.0;
              vec2 sq = p * sc + vec2(sin(T * 0.25 + float(i) * 2.0 + p.y * 3.0) * 0.5, T * (0.7 - float(i) * 0.2));
              vec2 id = floor(sq);
              vec2 o = vec2(hash(id + 5.0), hash(id + 9.0)) * 0.6 + 0.2;
              flakes += smoothstep(0.32, 0.0, length(fract(sq) - o)) * step(0.5, hash(id + float(i) * 3.0)) * (0.5 - float(i) * 0.15);
            }
            paper *= 1.0 - 0.35 * flakes * WINTER;
            // Snow drifted against the bottom of the screen outside.
            paper *= 1.0 - 0.25 * WINTER * smoothstep(0.1, 0.0, q.y - 0.03 * noise(vec2(p.x * 8.0, 0.0)));
          }
          vec2 cell = vec2(0.115, 0.165);
          vec2 g = abs(fract(q / cell + 0.5) - 0.5) * cell;
          float bar = smoothstep(0.0075, 0.0035, min(g.x, g.y));
          vec3 wood = vec3(0.09, 0.06, 0.04) * (amb * 3.0 + LIGHT * 0.25);
          paper = mix(paper, wood, bar * 0.92);
          // Thick frame posts and rail.
          float frame = smoothstep(0.016, 0.01, abs(p.x - sx)) + smoothstep(0.02, 0.012, abs(q.y));
          paper = mix(paper, vec3(0.06, 0.04, 0.03) * (amb * 3.0 + LIGHT * 0.12), clamp(frame, 0.0, 1.0));
          c = mix(c, paper, smoothstep(sx, sx + 0.004, p.x));
        }
        // Light bleeding onto the wall next to the screen.
        c += LIGHT * 0.07 * smoothstep(0.25, 0.0, sx - p.x) * step(p.x, sx) * smoothstep(-0.4, 0.0, p.y);
        // Floor and a long low walnut stand.
        if (p.y < -0.4) {
          vec3 floorC = vec3(0.32, 0.27, 0.16) * (amb * 2.0 + LIGHT * 0.1);
          floorC *= 0.85 + 0.15 * smoothstep(0.4, 0.6, fract(p.x * 18.0 + noise(p * vec2(4.0, 90.0)) * 0.3));
          c = floorC;
        }
        float top = -0.405;
        float front = -0.428;
        float bottom = -0.47;
        if (p.x > 0.02 && p.y < top && p.y > bottom) {
          float grain = fbm(vec2(p.x * 6.0, p.y * 140.0) + vec2(fbm(p * vec2(3.0, 50.0)) * 2.0, 0.0));
          vec3 walnut = mix(vec3(0.09, 0.05, 0.03), vec3(0.2, 0.12, 0.07), grain);
          if (p.y > front) {
            // Top surface reflects the bright screen.
            float refl = smoothstep(front, top, p.y);
            c = walnut * (amb * 3.0 + LIGHT * 0.5) + LIGHT * 0.12 * refl * (0.7 + 0.3 * noise(vec2(p.x * 50.0, 0.0)));
          } else {
            c = walnut * (amb * 1.6 + LIGHT * 0.05);
          }
          c *= smoothstep(0.02, 0.026, p.x);
          c += LIGHT * 0.25 * smoothstep(0.0025, 0.0, abs(p.y - top));
        }
        return c;
      }

      // Seasonal color of a single leaf; each leaf turns on its own schedule.
      vec3 leafColor(float h, float h2) {
        float s = S + (h - 0.5) * 0.55;
        vec3 spring = mix(vec3(0.36, 0.55, 0.12), vec3(0.5, 0.62, 0.18), h2);
        vec3 summer = mix(vec3(0.07, 0.24, 0.05), vec3(0.14, 0.32, 0.07), h2);
        vec3 autumn = h2 < 0.4 ? vec3(0.62, 0.07, 0.03) : (h2 < 0.75 ? vec3(0.85, 0.3, 0.04) : vec3(0.85, 0.58, 0.1));
        vec3 dry = vec3(0.32, 0.15, 0.06);
        vec3 c = mix(spring, summer, smoothstep(0.4, 1.3, s));
        c = mix(c, autumn, smoothstep(1.6, 2.3, s));
        return mix(c, dry, smoothstep(2.5, 3.0, s));
      }

      struct Hit { vec3 col; float a; };

      // A foliage pad: a dense, shadowed mass with individually lit leaves on its surface.
      Hit pad(vec2 p, vec2 c, vec2 size, float seed, float depth) {
        Hit o = Hit(vec3(0.0), 0.0);
        vec2 sw = vec2(0.0025 * sin(T * 0.5 + seed), 0.0012 * sin(T * 0.37 + seed * 2.0)) * (1.0 + c.y * 2.0);
        c += sw;
        vec2 rel = (p - c) / size;
        if (dot(rel, rel) > 2.2) return o;
        float rag = (fbm(p * 22.0 + seed) - 0.5) + (fbm(p * 8.0 + seed * 1.7) - 0.5) * 1.2;
        float e = length(rel * vec2(1.0, 1.0 + 0.4 * step(rel.y, 0.0))) + rag * 0.45;
        float lightDir = clamp(rel.y * 0.6 + rel.x * 0.2 + 0.5, 0.0, 1.0);
        float keepMass = 1.0 - FALL * 0.97;
        // Interior shadow mass.
        if (e < 0.9) {
          float m = smoothstep(0.9, 0.7, e) * keepMass;
          vec3 inner = leafColor(0.5, 0.5) * (0.04 + LIGHT * 0.08) * (0.5 + 0.5 * lightDir) * (0.5 + 0.8 * fbm(p * 180.0 + seed));
          o.col = inner;
          o.a = m;
        }
        // Leaves.
        float cs = 0.0068;
        vec2 base = floor(p / cs);
        float best = -1.0;
        for (int j = -1; j <= 1; j++)
          for (int i = -1; i <= 1; i++) {
            vec2 id = base + vec2(i, j);
            float h = hash(id + seed);
            float h2 = hash(id + seed + 7.7);
            float h3 = hash(id + seed + 3.3);
            vec2 lc = (id + 0.5 + (vec2(h2, h3) - 0.5) * 0.9) * cs;
            vec2 lr = (lc - c) / size;
            float le = length(lr * vec2(1.0, 1.0 + 0.4 * step(lr.y, 0.0))) + ((fbm(lc * 22.0 + seed) - 0.5) + (fbm(lc * 8.0 + seed * 1.7) - 0.5) * 1.2) * 0.45;
            if (le > 1.0) continue;
            // Lower, inner leaves are sparser.
            if (h < 0.12 + 0.3 * smoothstep(0.2, -0.8, lr.y)) continue;
            if (hash(id + seed + 11.0) < FALL * (0.9 + 0.1 * h)) continue;
            float grow = mix(0.55, 1.0, smoothstep(0.0, 0.9, S));
            float L = cs * (0.8 + 0.35 * h2) * grow;
            vec2 q = rot(h3 * 6.28) * (p - lc - sw * 0.5);
            // Maple-like palmate leaf: a pointed blade with soft lobes.
            float ang = atan(q.y, q.x);
            float lobes = 0.9 + 0.1 * cos(ang * 5.0);
            float d = length(q * vec2(0.85, 1.25)) - L * lobes * 0.62;
            float cov = smoothstep(0.0012 + depth * 0.004, -0.0003, d);
            if (cov <= 0.0) continue;
            float layer = cov * (1.0 - le * 0.2) + h * 0.01;
            if (layer < best) continue;
            best = layer;
            vec3 lcol = leafColor(h, h2);
            float vein = smoothstep(0.0012, 0.0, abs(q.y)) * step(0.0, q.x) * 0.25;
            float facing = 0.55 + 0.45 * sin(h * 40.0 + q.x / L * 2.0);
            float top = clamp(lr.y * 0.6 + 0.55, 0.0, 1.0);
            vec3 lit = lcol * (0.05 + LIGHT * (0.12 + 0.4 * top) * facing);
            // Backlight glows through the leaf edges like stained glass.
            float rim = smoothstep(-L * 0.25, 0.0, d) * (0.4 + 0.6 * top);
            lit += lcol * LIGHT * 0.55 * rim * smoothstep(0.3, 1.0, le + 0.3);
            lit *= 1.0 - vein;
            o.col = mix(o.col, lit, cov);
            o.a = max(o.a, cov);
          }
        // Cherry-like blossoms in spring.
        if (BLOOM > 0.0) {
          vec2 bc = floor(p / 0.017);
          for (int j = -1; j <= 1; j++)
            for (int i = -1; i <= 1; i++) {
              vec2 id = bc + vec2(i, j);
              float h = hash(id + seed + 41.0);
              if (h > BLOOM * 0.45 * smoothstep(0.35, 0.65, fbm(id * 0.35 + seed))) continue;
              vec2 fc = (id + 0.5 + (vec2(hash(id + seed + 5.0), hash(id + seed + 9.0)) - 0.5) * 0.8) * 0.017 + sw;
              vec2 fr = (fc - c) / size;
              if (length(fr) + (fbm(fc * 22.0 + seed) - 0.5) * 0.45 > 0.95) continue;
              vec2 q = rot(h * 9.0) * (p - fc);
              float a = atan(q.y, q.x);
              float r = 0.0062 * (0.75 + 0.25 * h) * (0.72 + 0.28 * abs(cos(a * 2.5)));
              float d = length(q) - r;
              float cov = smoothstep(0.0009 + depth * 0.004, -0.0003, d);
              if (cov <= 0.0) continue;
              vec3 petal = mix(vec3(0.98, 0.62, 0.72), vec3(1.0, 0.82, 0.86), hash(id + 2.0));
              vec3 lit = petal * (0.05 + LIGHT * (0.35 + 0.35 * clamp(fr.y + 0.5, 0.0, 1.0)));
              lit += petal * LIGHT * 0.4 * smoothstep(-0.002, 0.0, d);
              lit = mix(lit, vec3(0.6, 0.25, 0.1) * LIGHT * 0.4, smoothstep(0.0016, 0.0005, length(q)));
              o.col = mix(o.col, lit, cov);
              o.a = max(o.a, cov);
            }
        }
        // Fine ramified twigs, visible once the leaves thin out; snow settles along their tops.
        float twigVis = max(FALL, 0.25);
        vec2 org = c + vec2(0.0, -size.y * 0.35);
        for (int k = 0; k < 6; k++) {
          float fk = float(k);
          float dirx = mod(fk, 2.0) < 0.5 ? -1.0 : 1.0;
          float hk = hash(vec2(fk, seed));
          float ang = (0.08 + 0.28 * hk + fk * 0.04);
          float len = size.x * (0.55 + 0.4 * hash(vec2(seed, fk + 1.0)));
          vec2 mainEnd = org + vec2(dirx * cos(ang), sin(ang)) * len;
          for (int seg = 0; seg < 4; seg++) {
            float fs = float(seg);
            vec2 A;
            vec2 B;
            float r0;
            float r1;
            if (seg == 0) {
              A = org; B = mainEnd; r0 = 0.0024; r1 = 0.0009;
            } else {
              float u = 0.25 + fs * 0.22 + 0.06 * hash(vec2(fk, fs + seed));
              A = mix(org, mainEnd, u);
              float sa = 0.55 + 0.6 * hash(vec2(fs, fk + seed * 3.0));
              B = A + vec2(dirx * cos(sa), sin(sa)) * size.y * (0.55 + 0.4 * hash(vec2(fk + fs, seed + 9.0))) * (1.1 - u * 0.4);
              r0 = mix(0.0019, 0.0011, u); r1 = 0.0006;
            }
            vec2 ba = B - A;
            float sRaw = dot(p - A, ba) / dot(ba, ba);
            // Twigs arc a little.
            vec2 perp = normalize(vec2(-ba.y, ba.x));
            vec2 pc = p - perp * 0.04 * length(ba) * sin(clamp(sRaw, 0.0, 1.0) * PI) * dirx;
            float s2 = clamp(dot(pc - A, ba) / dot(ba, ba), 0.0, 1.0);
            vec2 dv = pc - A - ba * s2;
            float rr = mix(r0, r1, s2);
            float d = length(dv) - rr;
            float cov = smoothstep(0.0007, -0.0003, d) * twigVis;
            if (cov > 0.0) {
              vec3 tw = vec3(0.12, 0.09, 0.07) * (0.04 + LIGHT * 0.15) + vec3(0.25, 0.18, 0.12) * LIGHT * 0.45 * smoothstep(-rr, rr, dot(dv, vec2(0.7, 0.7)));
              float under = FALL > 0.5 ? 1.0 : 1.0 - o.a;
              o.col = mix(o.col, tw * (1.0 - depth * 0.3), cov * under);
              o.a = max(o.a, cov * under);
            }
            if (WINTER > 0.0 && sRaw > 0.0 && sRaw < 1.0) {
              vec2 up = perp.y < 0.0 ? -perp : perp;
              float above = dot(dv, up);
              float taper = sin(sRaw * PI);
              float thick = (0.0028 + 0.0018 * noise(p * 260.0)) * WINTER * smoothstep(0.15, 0.6, up.y) * pow(taper, 0.35);
              float sn = smoothstep(0.0005, -0.0004, above - rr - thick) * step(0.0, above) * step(abs(dot(dv, normalize(ba))), 0.0001);
              if (sn > 0.0) {
                vec3 snow = vec3(0.88, 0.9, 0.96) * (0.04 + LIGHT * (0.32 + 0.3 * smoothstep(rr, rr + thick, above)));
                o.col = mix(o.col, snow, sn);
                o.a = max(o.a, sn);
              }
            }
          }
        }
        if (false) {
          float capTop = rel.y - (0.15 + 0.35 * (1.0 - WINTER)) + (noise(p * 120.0) - 0.5) * 0.2 + rel.x * rel.x * 0.5;
          float cap = smoothstep(0.0, 0.08, capTop) * step(e, 1.02) * WINTER;
          vec3 snow = vec3(0.85, 0.88, 0.95) * (0.05 + LIGHT * 0.5 * (0.7 + 0.3 * noise(p * 300.0)));
          o.col = mix(o.col, snow, cap);
          o.a = max(o.a, cap);
        }
        o.col *= 1.0 - depth * 0.35;
        return o;
      }

      // Tapered limb segment. Returns distance and fills shading attributes of the nearest point.
      float limb(vec2 p, vec2 a, vec2 b, float ra, float rb, out float lat, out float along, out vec2 nrm) {
        vec2 ba = b - a;
        float s = clamp(dot(p - a, ba) / dot(ba, ba), 0.0, 1.0);
        float r = mix(ra, rb, s);
        vec2 dir = normalize(ba);
        nrm = vec2(-dir.y, dir.x);
        vec2 d = p - a - ba * s;
        lat = dot(d, nrm) / r;
        along = s * length(ba);
        return length(d) - r;
      }

      Hit wood(vec2 p) {
        // Trunk and branches as a chain of tapered segments.
        vec2 P[14];
        vec2 Q[14];
        float RA[14];
        float RB[14];
        P[0] = vec2(0.40, -0.31); Q[0] = vec2(0.445, -0.19); RA[0] = 0.042; RB[0] = 0.033;
        P[1] = Q[0];              Q[1] = vec2(0.375, -0.07); RA[1] = 0.033; RB[1] = 0.026;
        P[2] = Q[1];              Q[2] = vec2(0.43, 0.05);   RA[2] = 0.026; RB[2] = 0.018;
        P[3] = Q[2];              Q[3] = vec2(0.395, 0.16);  RA[3] = 0.018; RB[3] = 0.011;
        P[4] = Q[3];              Q[4] = vec2(0.415, 0.235); RA[4] = 0.011; RB[4] = 0.005;
        P[5] = vec2(0.43, -0.16); Q[5] = vec2(0.31, -0.115); RA[5] = 0.016; RB[5] = 0.009;
        P[6] = Q[5];              Q[6] = vec2(0.19, -0.095); RA[6] = 0.009; RB[6] = 0.004;
        P[7] = vec2(0.39, -0.08); Q[7] = vec2(0.52, -0.05);  RA[7] = 0.014; RB[7] = 0.008;
        P[8] = Q[7];              Q[8] = vec2(0.66, -0.025); RA[8] = 0.008; RB[8] = 0.0035;
        P[9] = vec2(0.42, 0.03);  Q[9] = vec2(0.30, 0.075);  RA[9] = 0.011; RB[9] = 0.006;
        P[10] = Q[9];             Q[10] = vec2(0.22, 0.085); RA[10] = 0.006; RB[10] = 0.003;
        P[11] = vec2(0.41, 0.12); Q[11] = vec2(0.5, 0.15);   RA[11] = 0.009; RB[11] = 0.005;
        P[12] = Q[11];            Q[12] = vec2(0.59, 0.155); RA[12] = 0.005; RB[12] = 0.0025;
        P[13] = vec2(0.30, -0.115); Q[13] = vec2(0.26, -0.06); RA[13] = 0.005; RB[13] = 0.0025;
        float d = 1e5;
        float lat = 0.0, along = 0.0;
        vec2 nrm = vec2(0.0, 1.0);
        for (int i = 0; i < 14; i++) {
          float l, a;
          vec2 n;
          float di = limb(p, P[i], Q[i], RA[i], RB[i], l, a, n);
          if (di < d) { lat = l; along = a + float(i) * 0.3; nrm = n; }
          d = i < 5 ? smin(d, di, 0.012) : min(d, di);
        }
        // Surface roots (nebari) flaring into the soil.
        vec2 rq = p - vec2(0.40, -0.305);
        float root = length(rq * vec2(1.0, 3.2)) - 0.075 + 0.012 * sin(rq.x * 90.0);
        root = max(root, -rq.y - 0.004);
        if (root < d) { lat = clamp(rq.x / 0.07, -1.0, 1.0); nrm = vec2(1.0, 0.0); }
        d = smin(d, root, 0.02);
        Hit o = Hit(vec3(0.0), 0.0);
        if (d > 0.002) return o;
        float x = clamp(lat, -1.0, 1.0);
        // Cylindrical shading lit from the screen behind-right.
        float facing = sqrt(max(1.0 - x * x, 0.0));
        float side = x * sign(nrm.x + 0.001);
        float diff = 0.25 + 0.75 * facing;
        float rim = smoothstep(0.55, 1.0, x * sign(nrm.x + nrm.y * 0.3 + 0.001)) ;
        // Twisting, fissured bark.
        vec2 bq = vec2(along * 60.0 + x * 2.5, x * 3.0);
        float fiss = fbm(bq * vec2(0.6, 1.0) + vec2(0.0, along * 8.0));
        float ridge = smoothstep(0.35, 0.6, fiss);
        vec3 bark = mix(vec3(0.07, 0.05, 0.04), vec3(0.26, 0.21, 0.17), ridge);
        bark = mix(bark, vec3(0.16, 0.18, 0.12), smoothstep(0.62, 0.8, fbm(p * 90.0)) * 0.6); // lichen
        o.col = bark * (0.06 + LIGHT * 0.22 * diff) + bark * LIGHT * 0.9 * rim;
        // Snow resting on the upper faces of limbs.
        float up = x * nrm.y;
        float snow = smoothstep(0.25, 0.6, up + (noise(p * 400.0) - 0.5) * 0.3) * WINTER;
        o.col = mix(o.col, vec3(0.85, 0.88, 0.95) * (0.05 + LIGHT * 0.5), snow);
        o.a = smoothstep(0.002, -0.0006, d);
        return o;
      }

      Hit potAndSoil(vec2 p) {
        Hit o = Hit(vec3(0.0), 0.0);
        vec2 c = vec2(0.42, -0.355);
        // Shallow rectangular pot, slightly tapered, with a lip and two feet.
        vec2 q = p - c;
        float taper = 1.0 - 0.07 * smoothstep(0.045, -0.05, q.y);
        float body = sdBox(vec2(q.x / taper, q.y), vec2(0.18, 0.042)) - 0.006;
        float lip = sdBox(q - vec2(0.0, 0.043), vec2(0.192, 0.006)) - 0.002;
        vec2 fq = vec2(abs(q.x) - 0.14, q.y + 0.05);
        float feet = sdBox(fq, vec2(0.018, 0.007)) - 0.002;
        float d = min(min(body, lip), feet);
        if (d < 0.002) {
          // Hand-glazed stoneware: deep blue-grey glaze pooling into rust where it thins.
          float pool = fbm(vec2(q.x * 30.0, q.y * 10.0) + 4.0);
          vec3 glaze = mix(vec3(0.06, 0.1, 0.14), vec3(0.16, 0.22, 0.27), pool);
          glaze = mix(glaze, vec3(0.28, 0.12, 0.05), smoothstep(0.6, 0.85, pool) * smoothstep(0.0, -0.04, q.y) * 0.6);
          float lightX = 0.4 + 0.6 * smoothstep(-0.2, 0.2, q.x);
          vec3 col = glaze * (0.08 + LIGHT * 0.22 * lightX);
          // Soft reflection of the bright screen.
          col += LIGHT * 0.18 * smoothstep(0.08, 0.0, abs(q.x - 0.12)) * smoothstep(-0.05, 0.03, q.y);
          col += LIGHT * 0.35 * smoothstep(0.003, 0.0, abs(q.y - 0.049)) * step(abs(q.x), 0.19);
          // Fine crackle in the glaze.
          vec2 cr = q * 70.0;
          float crack = smoothstep(0.06, 0.0, abs(noise(cr) - noise(cr * 1.9 + 3.0)));
          col *= 1.0 - crack * 0.15;
          if (lip < 0.0 && q.y > 0.04) col *= 1.15;
          if (feet < 0.0 && body > 0.0) col = vec3(0.04, 0.03, 0.03) * (0.2 + LIGHT * 0.2);
          o.col = col;
          o.a = smoothstep(0.0015, -0.0005, d);
        }
        // Moss mound and fine gravel at the soil line.
        float mossTop = -0.302 + 0.014 * smoothstep(0.19, 0.0, abs(p.x - 0.4)) + 0.004 * (fbm(vec2(p.x * 60.0, 0.0)) - 0.5);
        if (p.y < mossTop && p.y > -0.31 && abs(p.x - c.x) < 0.188) {
          float tex = fbm(p * 260.0);
          vec3 moss = mix(vec3(0.08, 0.16, 0.03), vec3(0.3, 0.42, 0.1), tex);
          moss = mix(moss, vec3(0.25, 0.2, 0.08), smoothstep(1.8, 3.0, S) * 0.6);
          vec3 col = moss * (0.06 + LIGHT * 0.35 * smoothstep(-0.31, mossTop, p.y));
          col = mix(col, vec3(0.85, 0.88, 0.95) * (0.05 + LIGHT * 0.45), WINTER * smoothstep(0.35, 0.55, tex));
          o.col = col;
          o.a = 1.0;
        }
        return o;
      }

      void main() {
        vec2 p = (gl_FragCoord.xy - resolution * 0.5) / resolution.y;
        float R = resolution.x / resolution.y * 0.5;
        T = time;
        S = clamp(season, 0.0, 3.0);
        FALL = smoothstep(2.25, 2.95, S);
        WINTER = smoothstep(2.55, 3.0, S);
        BLOOM = 1.0 - smoothstep(0.55, 1.15, S);
        // Morning -> midday -> golden hour -> blue dusk.
        vec3 l0 = vec3(1.0, 0.86, 0.72) * 1.0;
        vec3 l1 = vec3(1.0, 0.96, 0.9) * 1.15;
        vec3 l2 = vec3(1.0, 0.66, 0.36) * 1.0;
        vec3 l3 = vec3(0.55, 0.65, 0.9) * 0.85;
        LIGHT = S < 1.0 ? mix(l0, l1, S) : (S < 2.0 ? mix(l1, l2, S - 1.0) : mix(l2, l3, S - 2.0));
        LIGHT *= 0.95 * (1.0 + 0.08 * breath);

        vec3 c = room(p, R);

        // Soft contact shadow of the pot on the stand.
        c *= 1.0 - 0.6 * smoothstep(0.06, 0.0, sdBox(p - vec2(0.39, -0.41), vec2(0.21, 0.006)));

        // The bonsai is drawn in its own space, scaled up and anchored on the stand.
        vec2 tp = (p - vec2(0.38, -0.412)) / 1.2 + vec2(0.42, -0.412);
        // Back pads (behind the trunk), slightly defocused.
        Hit h;
        h = pad(tp, vec2(0.34, 0.0), vec2(0.09, 0.045), 13.0, 0.6); c = mix(c, h.col, h.a);
        h = pad(tp, vec2(0.5, 0.09), vec2(0.08, 0.04), 17.0, 0.6); c = mix(c, h.col, h.a);
        h = pad(tp, vec2(0.36, 0.175), vec2(0.07, 0.035), 19.0, 0.6); c = mix(c, h.col, h.a);

        h = wood(tp); c = mix(c, h.col, h.a);

        // Front pads.
        h = pad(tp, vec2(0.215, -0.075), vec2(0.115, 0.048), 1.0, 0.0); c = mix(c, h.col, h.a);
        h = pad(tp, vec2(0.635, -0.01), vec2(0.12, 0.05), 2.0, 0.0); c = mix(c, h.col, h.a);
        h = pad(tp, vec2(0.25, 0.1), vec2(0.09, 0.04), 3.0, 0.0); c = mix(c, h.col, h.a);
        h = pad(tp, vec2(0.575, 0.165), vec2(0.085, 0.038), 4.0, 0.0); c = mix(c, h.col, h.a);
        h = pad(tp, vec2(0.41, 0.255), vec2(0.075, 0.045), 5.0, 0.0); c = mix(c, h.col, h.a);

        h = potAndSoil(tp); c = mix(c, h.col, h.a);

        // Falling petals, leaves or snow depending on the season; dust motes in the light.
        float petals = BLOOM * 0.6;
        float leaves = smoothstep(1.8, 2.3, S) * (1.0 - WINTER);
        for (int i = 0; i < 18; i++) {
          float fi = float(i);
          float h1 = hash(vec2(fi, 3.0));
          float sp = 0.012 + 0.02 * hash(vec2(fi, 5.0));
          float ph = fract(T * sp + h1);
          vec2 m = vec2(0.05 + 0.75 * hash(vec2(fi, 7.0)), 0.4 - ph * 0.82);
          m.x += 0.03 * sin(T * 0.6 + fi * 2.1) + ph * 0.05;
          float fade = smoothstep(0.0, 0.08, ph) * smoothstep(1.0, 0.85, ph);
          vec2 q = rot(T * (0.8 + h1) + fi) * (p - m);
          float kind = hash(vec2(fi, 11.0));
          if (kind < petals) {
            float d = length(q * vec2(1.0, 1.9)) - 0.0045;
            c = mix(c, vec3(1.0, 0.8, 0.86) * LIGHT * 0.8, smoothstep(0.0008, -0.0004, d) * fade);
          } else if (kind < petals + leaves * 0.9) {
            float d = length(q * vec2(1.0, 1.6)) - 0.006 * (0.78 + 0.22 * cos(atan(q.y, q.x) * 5.0));
            vec3 lc = leafColor(hash(vec2(fi, 13.0)) + 0.3, hash(vec2(fi, 17.0)));
            c = mix(c, lc * LIGHT * (0.4 + 0.3 * sin(T * 2.0 + fi)), smoothstep(0.0008, -0.0004, d) * fade);
          }
        }
        if (false) {
          for (int i = 0; i < 2; i++) {
            float sc = 18.0 + float(i) * 14.0;
            vec2 q = p * sc + vec2(sin(T * 0.3 + float(i)) * 0.6, T * (0.9 - float(i) * 0.25));
            vec2 id = floor(q);
            vec2 o = vec2(hash(id + 5.0), hash(id + 9.0)) * 0.6 + 0.2;
            float f = smoothstep(0.14 - float(i) * 0.04, 0.0, length(fract(q) - o)) * step(0.55, hash(id + float(i) * 3.0));
            c += vec3(0.85, 0.9, 1.0) * LIGHT * 0.5 * f * WINTER;
          }
        }
        // Dust drifting in the window light.
        for (int i = 0; i < 12; i++) {
          float fi = float(i);
          vec2 m = vec2(hash(vec2(fi, 21.0)) * 1.2 - 0.3, fract(hash(vec2(fi, 23.0)) + T * 0.004 * (1.0 + hash(vec2(fi, 2.0)))) - 0.5);
          m.x += 0.03 * sin(T * 0.15 + fi);
          float d = length(p - m);
          c += LIGHT * 0.12 * smoothstep(0.003, 0.0, d) * (0.5 + 0.5 * sin(T * 0.8 + fi * 3.0)) * (1.0 - WINTER);
        }

        c *= 1.0 - 0.4 * smoothstep(0.55, 1.15, length(p * vec2(0.75, 1.1)));
        c += (hash(gl_FragCoord.xy + fract(T) * 91.0) - 0.5) * 0.008;
        result = vec4(max(c, 0.0), 1.0);
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
      gl.uniform1f(scene.uniform("season"), seasonLevel());
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
      gl.uniform1f(composite.uniform("exposure"), 1.45 + 0.06 * breathLevel());
      gl.uniform1f(composite.uniform("strength"), 0.56);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      const error = gl.getError();
      if (error !== gl.NO_ERROR) throw new Error(`WebGL render error: ${error}`);
      diagnostics.frames++;
      diagnostics.time = time;
    }

    // Breathing guide: the accretion disk glows brighter for 5s (inhale), then dims for 5s.
    // The tree moves through the seasons over the workday: spring at 9:00, summer at noon,
    // autumn at 15:00 and winter from 18:00.
    function seasonLevel() {
      if (typeof window.__bonsaiSeason === "number") return window.__bonsaiSeason;
      const now = new Date();
      const hours = now.getHours() + now.getMinutes() / 60 + now.getSeconds() / 3600;
      return Math.min(3, Math.max(0, (hours - 9) / 3));
    }
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
      fail(new Error("The graphics context was lost. Select another theme and return to Bonsai."));
    });
    draw(0);
    diagnostics.status = "ready";
    notify();
  } catch (error) {
    fail(error);
  }
})();
