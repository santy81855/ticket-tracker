"use strict";

(() => {
  const canvas = document.querySelector("#universe");
  const diagnostics = { status: "loading", error: null, frames: 0, paused: true, time: 0 };
  window.__cabin = diagnostics;

  function notify() {
    window.webkit?.messageHandlers?.cabin?.postMessage({
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
    if (!gl) throw new Error("Snowy cabin requires WebGL 2, which is unavailable on this Mac.");
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

      float ridge1(float x) {
        return 1.0 - abs(2.0 * noise(vec2(x, 0.37)) - 1.0);
      }

      const vec2 CABIN = vec2(0.30, -0.233);
      const vec2 LAMP = vec2(0.235, -0.36);
      const vec3 MOONDIR = vec3(-0.6, 0.45, 0.65);

      float groundY(float x) {
        return -0.245 + 0.022 * sin(x * 2.1 + 1.0) + 0.01 * sin(x * 5.3 + 2.0);
      }

      // Tiered pine silhouette; q is relative to the trunk base.
      float pine(vec2 q, float h, float px, float seed, float tiers, out float snow) {
        snow = 0.0;
        vec2 n = q / h;
        if (n.y < -0.02 || n.y > 1.05) return 0.0;
        float k = n.y * (tiers + floor(seed * 3.0)) + seed * 3.0;
        float phase = fract(k);
        float width = (1.0 - n.y) * 0.36 * (0.5 + 0.5 * pow(1.0 - phase, 1.4));
        width *= 0.9 + 0.2 * noise(vec2(n.x * 60.0 + seed * 40.0, n.y * 70.0));
        float edge = abs(n.x) - width;
        float cov = smoothstep(px / h, -px / h, edge);
        float trunk = step(n.y, 0.07) * smoothstep(px / h, -px / h, abs(n.x) - 0.035);
        cov = max(cov, trunk * 0.9);
        float shelf = smoothstep(0.7, 0.2, phase) * smoothstep(0.02, 0.12, phase) * smoothstep(-0.05, -0.008, edge);
        snow = clamp(shelf * smoothstep(0.3, 0.6, noise(n * 90.0 + seed * 9.0)), 0.0, 1.0);
        snow *= 0.75 + 0.5 * smoothstep(0.1, -0.2, n.x / max(width, 0.01));
        return cov;
      }

      // A snowy hill covered with pines. Returns coverage and snow amount.
      vec2 forest(vec2 p, float base, float cellW, float hMin, float hMax, float seed, float px, vec2 clearing) {
        float hill = base + 0.03 * sin(p.x * 2.4 + seed) + 0.015 * sin(p.x * 6.1 + seed * 3.0);
        float ground = smoothstep(px, -px, p.y - hill);
        vec2 res = vec2(ground, ground);
        float cell0 = floor(p.x / cellW);
        for (int i = -2; i <= 2; i++) {
          float cell = cell0 + float(i);
          float r = hash(vec2(cell, seed));
          if (r < 0.18) continue;
          float cx = (cell + 0.15 + 0.7 * hash(vec2(cell, seed + 3.0))) * cellW;
          if (min(abs(cx - clearing.x), abs(cx - clearing.y)) < 0.05 + cellW * 0.5) continue;
          float h = mix(hMin, hMax, hash(vec2(cell, seed + 7.0)));
          float by = base + 0.03 * sin(cx * 2.4 + seed) + 0.015 * sin(cx * 6.1 + seed * 3.0) - 0.004;
          float s;
          float c = pine(vec2(p.x - cx, p.y - by), h, px, r, 4.0, s);
          if (c > 0.0) {
            res.y = mix(res.y, s, c);
            res.x = max(res.x, c);
          }
        }
        return res;
      }

      vec3 skyColor(vec2 p, float t) {
        vec3 c = mix(vec3(0.05, 0.09, 0.19), vec3(0.012, 0.018, 0.055), smoothstep(-0.15, 0.5, p.y));
        c += vec3(0.10, 0.12, 0.2) * exp(-max(p.y + 0.08, 0.0) * 7.0) * 0.5;
        // Stars, twinkling and fading near the horizon.
        vec2 g = p * 220.0;
        vec2 id = floor(g);
        float h = hash(id);
        if (h > 0.985) {
          vec2 off = vec2(hash(id + 1.3), hash(id + 2.7)) - 0.5;
          float d = length(fract(g) - 0.5 - off * 0.6);
          float tw = 0.6 + 0.4 * sin(t * (1.0 + h * 3.0) + h * 60.0);
          c += vec3(0.8, 0.85, 1.0) * smoothstep(0.22, 0.0, d) * tw * (h - 0.985) * 60.0 * smoothstep(-0.05, 0.25, p.y);
        }
        // Moon with a soft halo and subtle maria.
        vec2 mp = vec2(-0.52, 0.31);
        float md = length(p - mp);
        float disc = smoothstep(0.034, 0.031, md);
        float maria = fbm((p - mp) * 60.0 + 3.0);
        c = mix(c, vec3(1.0, 0.97, 0.9) * (1.9 - 0.6 * smoothstep(0.45, 0.7, maria)), disc);
        c += vec3(0.45, 0.55, 0.8) * (0.1 * exp(-md * 9.0) + 0.05 * exp(-md * 3.0)) * (1.0 - disc);
        // An occasional shooting star.
        float sk = floor(t / 17.0);
        float sl = mod(t, 17.0);
        if (sl < 0.9 && hash(vec2(sk, 4.0)) > 0.35) {
          vec2 dir = normalize(vec2(-1.0, -0.38));
          vec2 head = vec2(hash(vec2(sk, 1.0)) * 0.9 - 0.2, 0.44 - hash(vec2(sk, 2.0)) * 0.1) + dir * sl * 0.45;
          vec2 rel = p - head;
          float along = clamp(dot(rel, -dir), 0.0, 0.14);
          float dist = length(rel + dir * along);
          float fade = smoothstep(0.0, 0.15, sl) * smoothstep(0.9, 0.5, sl);
          c += vec3(0.85, 0.9, 1.0) * smoothstep(0.0022, 0.0, dist) * (1.0 - along / 0.14) * fade * 1.8;
        }
        // Thin drifting clouds lit by the moon.
        vec2 cq = vec2(p.x * 1.4 + t * 0.006, p.y * 4.5);
        float cl = smoothstep(0.5, 0.85, fbm(cq + vec2(0.0, 2.0)) * (0.7 + 0.5 * fbm(cq * 2.3)));
        cl *= smoothstep(-0.05, 0.15, p.y);
        vec3 cloudCol = vec3(0.12, 0.15, 0.25) + vec3(0.55, 0.6, 0.75) * exp(-md * 5.0);
        c = mix(c, cloudCol, cl * 0.75);
        return c;
      }

      float cabinWindow(vec2 c, vec2 center, vec2 size) {
        vec2 d = abs(c - center) - size;
        float inside = step(max(d.x, d.y), 0.0);
        vec2 m = abs(c - center);
        float mullion = step(m.x, 0.0018) + step(m.y, 0.0018);
        return inside * (1.0 - clamp(mullion, 0.0, 1.0));
      }

      float flicker(float t) {
        return 0.86 + 0.08 * sin(t * 7.3) + 0.05 * sin(t * 13.1 + 1.0) + 0.04 * noise(vec2(t * 4.0, 1.0));
      }

      // Cabin color with alpha; glow is warm window light.
      vec4 cabin(vec2 c, float t, out float glow) {
        glow = 0.0;
        if (abs(c.x) > 0.2 || c.y < -0.02 || c.y > 0.22) return vec4(0.0);
        float warm = flicker(t) * (1.0 + 0.35 * breath);
        float halfW = 0.12;
        float wallTop = 0.078;
        float roofSlope = 0.62;
        float peak = wallTop + halfW * roofSlope;
        vec4 col = vec4(0.0);
        // Log walls and gable.
        float gable = wallTop + (halfW - abs(c.x)) * roofSlope;
        if (abs(c.x) < halfW && c.y > -0.01 && c.y < gable) {
          float logs = 0.5 + 0.5 * sin(c.y * 360.0);
          vec3 wood = vec3(0.075, 0.045, 0.03) * (0.6 + 0.4 * logs) * (0.85 + 0.3 * noise(c * vec2(30.0, 300.0)));
          wood += vec3(0.04, 0.05, 0.08) * 0.3;
          // Warm light leaks onto the logs around the windows.
          float spill = exp(-length((c - vec2(-0.068, 0.045)) * vec2(1.0, 1.6)) * 30.0) + exp(-length((c - vec2(0.068, 0.045)) * vec2(1.0, 1.6)) * 30.0);
          wood += vec3(0.5, 0.25, 0.08) * spill * 0.25 * warm;
          col = vec4(wood, 1.0);
          float w = cabinWindow(c, vec2(-0.068, 0.045), vec2(0.022, 0.018)) + cabinWindow(c, vec2(0.068, 0.045), vec2(0.022, 0.018));
          float attic = step(length(c - vec2(0.0, wallTop + 0.03)), 0.011) * (1.0 - step(abs(c.x), 0.0015));
          vec3 lamp = vec3(1.0, 0.58, 0.24) * 3.2 * warm;
          vec3 inner = lamp * (0.8 + 0.25 * noise(c * 90.0 + t * 0.3));
          col.rgb = mix(col.rgb, inner, clamp(w, 0.0, 1.0));
          col.rgb = mix(col.rgb, lamp * 0.45, attic);
          glow = clamp(w, 0.0, 1.0) + attic * 0.4;
          // Door with a warm crack of light.
          vec2 dd = abs(c - vec2(0.0, 0.03)) - vec2(0.018, 0.04);
          if (max(dd.x, dd.y) < 0.0) {
            col.rgb = vec3(0.05, 0.028, 0.018) * (0.7 + 0.3 * sin(c.x * 900.0));
            col.rgb += lamp * 0.5 * smoothstep(0.0025, 0.0, abs(c.x - 0.017));
          }
          // Snow drift piled against the base.
          float drift = 0.01 + 0.006 * noise(vec2(c.x * 60.0, 0.0)) + 0.008 * smoothstep(0.09, 0.12, abs(c.x));
          if (c.y < drift) col.rgb = vec3(0.42, 0.5, 0.75) * 0.8 + vec3(1.0, 0.55, 0.22) * 0.18 * warm;
        }
        // Chimney with a snow cap.
        vec2 ch = c - vec2(0.065, 0.0);
        if (abs(ch.x) < 0.012 && ch.y > gable - 0.01 && ch.y < peak + 0.025) {
          float bricks = step(0.15, fract(ch.y * 260.0)) * step(0.1, fract(ch.x * 120.0 + floor(ch.y * 260.0) * 0.5));
          col = vec4(vec3(0.09, 0.05, 0.04) * (0.55 + 0.45 * bricks), 1.0);
          if (ch.y > peak + 0.019) col.rgb = vec3(0.55, 0.62, 0.82);
        }
        // Roof eaves covered in thick, lumpy snow.
        float slope = (c.y - wallTop) - (halfW - abs(c.x)) * roofSlope;
        float lump = 0.004 * noise(vec2(c.x * 70.0, 2.0)) + 0.003 * noise(vec2(c.x * 180.0, 5.0));
        if (abs(c.x) < halfW + 0.028 && slope > -0.004 && slope < 0.018 + lump && abs(ch.x) > 0.012 - 0.02 * step(ch.y, gable)) {
          float depth = clamp((slope + 0.004) / (0.022 + lump), 0.0, 1.0);
          vec3 snowCol = mix(vec3(0.2, 0.25, 0.42), vec3(0.62, 0.7, 0.92), smoothstep(0.1, 0.8, depth));
          snowCol *= 0.9 + 0.2 * smoothstep(0.0, -0.1, c.x);
          col = vec4(snowCol, 1.0);
        }
        // Icicles along the eaves.
        float eave = (halfW + 0.028 - abs(c.x));
        float ib = wallTop - 0.028 * roofSlope - 0.004;
        float lineY = (c.y - wallTop) - (halfW - abs(c.x)) * roofSlope + 0.004;
        if (eave > 0.0 && eave < 0.028 && lineY < 0.0) {
          float ic = fract(abs(c.x) * 260.0);
          float len = 0.006 * hash(vec2(floor(abs(c.x) * 260.0), sign(c.x)));
          if (lineY > -len * (1.0 - abs(ic - 0.5) * 2.0) && col.a < 0.5) col = vec4(0.45, 0.55, 0.78, 0.9);
        }
        return col;
      }

      const vec2 CHIMNEY = vec2(0.065, 0.1784);

      float smoke(vec2 p, float t, vec2 origin, float scale) {
        vec2 s = (p - origin) / scale;
        if (abs(s.x) > 0.6 || s.y > 0.9) return 0.0;
        if (s.y < 0.0) return 0.0;
        float drift = s.y * 0.12 + 1.1 * s.y * s.y + 0.01 * sin(s.y * 16.0 - t * 0.9);
        float w = 0.005 + s.y * 0.16;
        float x = (s.x - drift) / w;
        float d = fbm(vec2(s.x * 18.0 - t * 0.06, s.y * 10.0 - t * 0.35));
        float puff = exp(-x * x * 1.2) * smoothstep(0.25, 0.75, d + 0.25 - s.y * 0.6);
        return puff * smoothstep(0.0, 0.01, s.y) * exp(-s.y * 2.6);
      }

      float flakes(vec2 p, float t, float s, float speed, float size, float blur, float seed) {
        vec2 q = p * s;
        q.y += t * speed * s;
        q.x += (t * speed * 0.35 + 0.1 * sin(t * 0.13) + 0.07 * sin(t * 0.051 + 2.0)) * s + 0.4 * sin(q.y * 0.15 + seed);
        vec2 id = floor(q);
        float h = hash(id + seed);
        if (h < 0.62) return 0.0;
        vec2 off = (vec2(hash(id + seed + 3.1), hash(id + seed + 7.7)) - 0.5) * 0.5;
        off.x += 0.08 * sin(t * (0.8 + h * 1.5) + h * 40.0);
        float d = length(fract(q) - 0.5 - off);
        float r = size * (0.6 + 0.4 * hash(id + seed + 11.0));
        return smoothstep(r, r * (1.0 - blur), d) * (0.6 + 0.4 * h);
      }

      float hillY(float x, float base, float seed) {
        return base + 0.03 * sin(x * 2.4 + seed) + 0.015 * sin(x * 6.1 + seed * 3.0);
      }

      vec3 bulbColor(float h) {
        return h < 0.25 ? vec3(1.0, 0.18, 0.12) : h < 0.5 ? vec3(1.0, 0.72, 0.25) : h < 0.75 ? vec3(0.2, 0.9, 0.35) : vec3(0.3, 0.55, 1.0);
      }

      // A small glowing bulb with a soft halo.
      float bulb(float d, float r) {
        return smoothstep(r, r * 0.3, d) * 2.5 + exp(-d / r * 1.6) * 0.5;
      }

      // A cabin further up the valley, fogged by distance.
      void farHouse(inout vec3 c, vec2 p, vec2 pos, float s, float flip, float haze, float t, vec3 fogCol) {
        vec2 lc = (p - pos) / s;
        lc.x *= flip;
        float g;
        vec4 h = cabin(lc, t + pos.x * 37.0, g);
        c = mix(c, mix(h.rgb, fogCol, haze * (1.0 - 0.55 * g)), h.a);
        float sm = smoke(p, t + pos.x * 23.0, pos + vec2(CHIMNEY.x * flip, CHIMNEY.y) * s, s);
        c = mix(c, mix(vec3(0.3, 0.34, 0.48), fogCol, haze), clamp(sm, 0.0, 0.8) * 0.6);
        c += vec3(1.0, 0.55, 0.22) * 0.05 * exp(-length(lc - vec2(0.0, 0.045)) * 12.0) * flicker(t + pos.x * 37.0);
      }

      void main() {
        vec2 p = (gl_FragCoord.xy - resolution * 0.5) / resolution.y;
        float t = time;
        float px = 1.0 / resolution.y;
        float warm = flicker(t) * (1.0 + 0.35 * breath);
        vec3 c = skyColor(p, t);
        vec3 fogCol = vec3(0.07, 0.1, 0.19);
        vec3 snowLit = vec3(0.42, 0.5, 0.75);
        vec3 pineCol = vec3(0.012, 0.025, 0.035);

        // Distant snowy mountains under moonlight.
        float mh = -0.03 + 0.13 * fbm(vec2(p.x * 1.6 + 3.0, 0.5)) + 0.05 * (ridge1(p.x * 3.0 + 1.0) - 0.5);
        if (p.y < mh) {
          float e = 0.004;
          float slope = (fbm(vec2((p.x + e) * 1.6 + 3.0, 0.5)) - fbm(vec2((p.x - e) * 1.6 + 3.0, 0.5))) / e;
          float lit = clamp(0.55 - slope * 0.25, 0.15, 1.0);
          float streak = smoothstep(0.35, 0.75, fbm(vec2(p.x * 9.0 + p.y * 14.0, p.y * 6.0 - p.x * 3.0)));
          vec3 m = mix(vec3(0.06, 0.08, 0.16), vec3(0.3, 0.36, 0.55), lit * (0.6 + 0.4 * streak));
          m = mix(m, fogCol, smoothstep(mh - 0.2, mh, p.y) * 0.25 + 0.35);
          c = mix(c, m, smoothstep(0.0, px * 2.0, mh - p.y));
        }

        // Forested hills, back to front, separated by layers of mist.
        float layers[3] = float[3](-0.105, -0.16, -0.205);
        for (int i = 0; i < 3; i++) {
          float fi = float(i);
          float cellW = 0.022 + fi * 0.016;
          vec2 clearing = i == 0 ? vec2(9.0) : i == 1 ? vec2(-0.42, 0.62) : vec2(-0.42, 0.62);
          vec2 f = forest(p, layers[i], cellW, 0.04 + fi * 0.03, 0.08 + fi * 0.05, 11.0 + fi * 17.0, px, clearing);
          vec3 lc = mix(pineCol, snowLit * (0.8 + 0.25 * fbm(p * 50.0)), f.y);
          float haze = 0.62 - fi * 0.2;
          lc = mix(lc, fogCol, haze);
          c = mix(c, lc, f.x);
          float sd = 11.0 + fi * 17.0;
          if (i == 1) {
            farHouse(c, p, vec2(-0.42, hillY(-0.42, layers[1], sd) - 0.003), 0.3, -1.0, haze * 0.8, t, fogCol);
            farHouse(c, p, vec2(0.62, hillY(0.62, layers[1], sd) - 0.003), 0.26, 1.0, haze * 0.8, t, fogCol);
          }
          if (i == 2) farHouse(c, p, vec2(-0.05, hillY(-0.05, layers[2], sd) - 0.004), 0.42, -1.0, haze * 0.7, t, fogCol);
          // Ground mist pooling in the valley in front of this layer.
          float mist = fbm(vec2(p.x * 3.0 + t * 0.012 * (fi + 1.0), p.y * 9.0 + fi * 4.0));
          c = mix(c, fogCol * 1.3, smoothstep(0.035, 0.0, abs(p.y - layers[i] + 0.012)) * mist * 0.35);
        }

        // Foreground snowfield with drifts and sparkles.
        float gy = groundY(p.x);
        if (p.y < gy + px) {
          float drift = fbm(vec2(p.x * 4.0, p.y * 14.0));
          float ripple = fbm(vec2(p.x * 3.0 + p.y * 2.0, p.y * 32.0));
          float shade = 0.72 + 0.3 * drift + 0.12 * (ripple - 0.5) - 0.35 * smoothstep(-0.25, -0.5, p.y) * (1.0 - drift);
          float pathX = CABIN.x - (CABIN.y - 0.012 - p.y) * 0.9 + 0.03 * sin(p.y * 18.0);
          float pathW = 0.014 + (CABIN.y - p.y) * 0.1;
          float path = smoothstep(pathW, pathW * 0.4, abs(p.x - pathX)) * step(p.y, CABIN.y - 0.008);
          float prints = smoothstep(0.55, 0.8, noise(vec2(p.x * 300.0, p.y * 180.0)));
          shade *= 1.0 - path * (0.13 + 0.1 * prints);
          vec3 g = snowLit * shade * 0.85;
          g = mix(g, fogCol * 1.4, smoothstep(gy - 0.05, gy, p.y) * 0.3);
          // Warm light spilling from the windows and door onto the snow.
          vec2 w1 = p - (CABIN + vec2(-0.068, -0.03));
          vec2 w2 = p - (CABIN + vec2(0.068, -0.03));
          vec2 dr = p - (CABIN + vec2(0.0, -0.035));
          float spill = exp(-dot(w1 * vec2(9.0, 22.0), w1 * vec2(9.0, 22.0))) + exp(-dot(w2 * vec2(9.0, 22.0), w2 * vec2(9.0, 22.0)));
          spill += 0.6 * exp(-dot(dr * vec2(14.0, 18.0), dr * vec2(14.0, 18.0)));
          spill += 0.35 * exp(-length((p - CABIN) * vec2(2.2, 5.0)) * 3.0);
          g += vec3(1.0, 0.55, 0.22) * spill * 0.55 * warm;
          // Glinting ice crystals.
          vec2 sg = p * vec2(420.0, 600.0);
          vec2 sid = floor(sg);
          float sh = hash(sid + 5.0);
          if (sh > 0.992) {
            float tw = pow(max(sin(t * (0.6 + sh * 2.0) + sh * 90.0), 0.0), 24.0);
            g += vec3(0.85, 0.9, 1.0) * tw * smoothstep(0.4, 0.0, length(fract(sg) - 0.5)) * 2.5;
          }
          // Pool of lamplight on the snow.
          vec2 lp = (p - LAMP) * vec2(10.0, 32.0);
          g += vec3(1.0, 0.62, 0.3) * 0.45 * exp(-dot(lp, lp)) * warm;
          // Frozen pond reflecting the sky and moon, dusted with snow.
          vec2 pc = vec2(-0.36, -0.375);
          float e = length((p - pc) / vec2(0.24, 0.048)) + 0.12 * (noise(p * vec2(9.0, 30.0)) - 0.5);
          if (e < 1.0) {
            vec3 refl = skyColor(vec2(p.x, 0.12 + (pc.y + 0.048 - p.y) * 2.5), t) * 0.3;
            vec3 ice = mix(vec3(0.015, 0.03, 0.06), vec3(0.05, 0.08, 0.15), smoothstep(-0.04, 0.04, p.y - pc.y)) + refl;
            ice += vec3(0.6, 0.65, 0.8) * 0.3 * exp(-abs(p.x + 0.52) * 22.0) * (0.6 + 0.4 * noise(vec2(p.x * 20.0, p.y * 200.0 + t * 0.3)));
            float crack = smoothstep(0.965, 0.995, 1.0 - abs(2.0 * noise(p * vec2(45.0, 110.0)) - 1.0));
            ice += vec3(0.2, 0.25, 0.35) * crack * 0.5;
            float dust = smoothstep(0.62, 0.8, fbm(p * vec2(10.0, 40.0)));
            ice = mix(ice, g * 0.8, dust * 0.45);
            ice += vec3(1.0, 0.6, 0.3) * 0.05 * exp(-abs(p.x + 0.15) * 12.0) * warm;
            g = mix(g, ice, smoothstep(1.0, 0.86, e));
            g += snowLit * 0.18 * smoothstep(0.8, 0.95, e) * smoothstep(1.0, 0.95, e);
          }
          c = mix(c, g, smoothstep(px, -px, p.y - gy));
        }

        // The cabin, its warm glow and chimney smoke.
        float glow;
        vec2 lc = p - CABIN;
        vec4 cb = cabin(lc, t, glow);
        c = mix(c, cb.rgb, cb.a);
        // String lights chasing along the eaves.
        if (abs(lc.x) < 0.15 && lc.y > 0.03 && lc.y < 0.17) {
          float bi = floor(lc.x / 0.012);
          float bx = (bi + 0.5) * 0.012;
          float by = 0.078 + (0.12 - abs(bx)) * 0.62 - 0.009;
          float d = length(lc - vec2(bx, by));
          float h = fract(bi * 0.25 + 0.01);
          float chase = 0.55 + 0.45 * sin(t * 2.2 - bi * 1.3);
          if (abs(bx) < 0.14) c += bulbColor(h) * bulb(d, 0.0022) * chase;
        }
        float sm = smoke(p, t, CABIN + CHIMNEY, 1.0);
        vec3 smokeCol = vec3(0.32, 0.36, 0.5) + vec3(0.35, 0.18, 0.08) * exp(-max(p.y - CABIN.y - 0.15, 0.0) * 25.0) * 0.4;
        c = mix(c, smokeCol, clamp(sm, 0.0, 0.8));
        vec2 hc = (p - (CABIN + vec2(0.0, 0.045))) * vec2(0.8, 1.4);
        c += vec3(1.0, 0.55, 0.22) * 0.1 * exp(-length(hc) * 8.0) * warm;

        // A decorated pine beside the cabin with twinkling lights and a star.
        vec2 xt = p - (CABIN + vec2(-0.17, -0.004));
        float xs;
        float xc = pine(xt, 0.15, px, 0.42, 6.0, xs);
        c = mix(c, mix(pineCol * 1.4, snowLit * 0.8, xs * 0.7), xc);
        if (xc > 0.0 || length(xt - vec2(0.0, 0.08)) < 0.09) {
          vec2 gq = xt / 0.0105;
          vec2 gid = floor(gq);
          float gh = hash(gid + 50.0);
          vec2 goff = (vec2(hash(gid + 51.0), hash(gid + 52.0)) - 0.5) * 0.5;
          vec2 bc = (gid + 0.5 + goff) * 0.0105;
          float inside = step(abs(bc.x), (1.0 - bc.y / 0.15) * 0.3 * 0.15) * step(0.01, bc.y) * step(bc.y, 0.135);
          float tw = 0.4 + 0.6 * smoothstep(-0.3, 0.8, sin(t * (1.0 + gh * 2.0) + gh * 70.0));
          if (gh > 0.35) c += bulbColor(fract(gh * 7.3)) * bulb(length(xt - bc), 0.0019) * tw * inside;
          vec2 st = xt - vec2(0.0, 0.152);
          float ang = atan(st.y, st.x);
          float star = smoothstep(0.0065 * (0.55 + 0.45 * cos(5.0 * ang - 1.5708)), 0.0, length(st));
          c += vec3(1.0, 0.82, 0.4) * (star * 3.0 + exp(-length(st) * 120.0) * 0.4) * (0.9 + 0.1 * sin(t * 3.0));
        }

        // A snowman keeping watch by the path.
        vec2 sw = p - vec2(0.05, -0.318);
        float b1 = length(sw - vec2(0.0, 0.02)) - 0.021;
        float b2 = length(sw - vec2(0.002, 0.052)) - 0.015;
        float b3 = length(sw - vec2(0.003, 0.076)) - 0.0105;
        float body = min(min(b1, b2), b3);
        if (body < px) {
          vec2 nrm = normalize(sw - (b1 < b2 ? vec2(0.0, 0.02) : b2 < b3 ? vec2(0.002, 0.052) : vec2(0.003, 0.076)));
          float lit = 0.55 + 0.45 * dot(nrm, normalize(vec2(-0.6, 0.8)));
          vec3 sc = snowLit * (0.5 + 0.6 * lit);
          float scarf = step(abs(sw.y - 0.065), 0.0035) * step(abs(sw.x - 0.002), 0.015);
          scarf = max(scarf, step(abs(sw.x - 0.009), 0.003) * step(0.045, sw.y) * step(sw.y, 0.066));
          sc = mix(sc, vec3(0.5, 0.06, 0.05), scarf);
          float eyes = step(length(vec2(abs(sw.x - 0.003) - 0.004, sw.y - 0.079)), 0.0014);
          float buttons = step(length(vec2(sw.x - 0.002, mod(sw.y - 0.046, 0.009) - 0.0045)), 0.0013) * step(0.038, sw.y) * step(sw.y, 0.06);
          sc = mix(sc, vec3(0.02), max(eyes, buttons));
          c = mix(c, sc, smoothstep(px, -px, body));
        }
        vec2 nose = sw - vec2(0.0, 0.0745);
        if (nose.x < 0.0 && nose.x > -0.012 && abs(nose.y) < 0.0018 * (1.0 + nose.x / 0.012)) c = vec3(0.7, 0.28, 0.05);
        vec2 hat = sw - vec2(0.003, 0.086);
        if ((abs(hat.x) < 0.007 && hat.y > 0.0 && hat.y < 0.013) || (abs(hat.x) < 0.011 && abs(hat.y) < 0.0012)) c = vec3(0.015, 0.015, 0.02);

        // Snow-capped split-rail fence running off to the right.
        if (p.x > 0.46 && p.x < 0.95) {
          float fx = p.x;
          float fy = groundY(fx) - 0.004;
          float post = mod(fx - 0.46, 0.05);
          float postX = fx - post + 0.002;
          vec2 pp = vec2(post - 0.002, p.y - groundY(postX));
          vec3 wood = vec3(0.06, 0.04, 0.03);
          if (abs(pp.x) < 0.0025 && pp.y > -0.005 && pp.y < 0.032) c = pp.y > 0.028 ? snowLit * 0.95 : wood;
          float rail1 = abs(p.y - fy - 0.012);
          float rail2 = abs(p.y - fy - 0.025);
          if (rail1 < 0.0016 || rail2 < 0.0016) c = wood * 1.2;
          if (p.y - fy - 0.025 > 0.0016 && p.y - fy - 0.025 < 0.0038 + 0.0015 * noise(vec2(fx * 200.0, 0.0))) c = snowLit * 0.9;
        }

        // Lamppost by the path.
        vec2 lq = p - LAMP;
        if (abs(lq.x) < 0.0022 && lq.y > 0.0 && lq.y < 0.088) c = vec3(0.02, 0.02, 0.025);
        vec2 lb = lq - vec2(0.0, 0.096);
        if (abs(lb.x) < 0.0065 && abs(lb.y) < 0.009) {
          float frame = step(0.0045, abs(lb.x)) + step(0.0072, abs(lb.y));
          c = frame > 0.0 ? vec3(0.02, 0.02, 0.025) : vec3(1.0, 0.7, 0.35) * 3.0 * warm;
        }
        if (abs(lb.x) < 0.0085 - (lb.y - 0.009) * 0.8 && lb.y > 0.009 && lb.y < 0.015) c = lb.y > 0.0125 ? snowLit : vec3(0.02, 0.02, 0.025);
        c += vec3(1.0, 0.62, 0.3) * (0.12 * exp(-length(lb) * 40.0) + 0.04 * exp(-length(lb) * 9.0)) * warm;

        // Framing pines in the foreground.
        float s1, s2;
        float t1 = pine(p - vec2(-0.8, -0.58), 0.82, px, 0.31, 9.0, s1);
        float t2 = pine(p - vec2(0.84, -0.6), 0.7, px, 0.77, 8.0, s2);
        vec3 f1 = mix(vec3(0.008, 0.016, 0.022), snowLit * 0.7, s1 * 0.8);
        vec3 f2 = mix(vec3(0.008, 0.016, 0.022), snowLit * 0.7, s2 * 0.8);
        c = mix(c, f1, t1);
        c = mix(c, f2, t2);

        // Falling snow at several depths; near flakes are larger and defocused.
        float sn = 0.0;
        sn += flakes(p, t, 70.0, 0.035, 0.1, 0.3, 1.0) * 0.22;
        sn += flakes(p, t, 38.0, 0.05, 0.1, 0.35, 7.0) * 0.4;
        sn += flakes(p, t, 20.0, 0.07, 0.11, 0.5, 13.0) * 0.75;
        sn += flakes(p, t, 9.0, 0.1, 0.09, 0.8, 23.0) * 0.6;
        float nearWarm = exp(-length((p - CABIN) * vec2(1.5, 2.5)) * 3.5) + exp(-length(p - LAMP - vec2(0.0, 0.096)) * 14.0);
        c += mix(vec3(0.65, 0.72, 0.9), vec3(1.0, 0.7, 0.45), clamp(nearWarm, 0.0, 1.0) * 0.6) * sn * (0.55 + 0.8 * clamp(nearWarm - 0.3, 0.0, 1.0));

        // Gentle vignette.
        c *= 1.0 - 0.35 * smoothstep(0.5, 1.1, length(p * vec2(0.85, 1.2)));
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

    // Breathing guide: the accretion disk glows brighter for 5s (inhale), then dims for 5s.
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
      fail(new Error("The graphics context was lost. Select another theme and return to Snowy cabin."));
    });
    draw(0);
    diagnostics.status = "ready";
    notify();
  } catch (error) {
    fail(error);
  }
})();
