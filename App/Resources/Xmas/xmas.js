"use strict";

(() => {
  const canvas = document.querySelector("#universe");
  const diagnostics = { status: "loading", error: null, frames: 0, paused: true, time: 0 };
  window.__xmas = diagnostics;

  function notify() {
    window.webkit?.messageHandlers?.xmas?.postMessage({
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
    if (!gl) throw new Error("Christmas requires WebGL 2, which is unavailable on this Mac.");
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

      float sdBox(vec2 p, vec2 b) {
        vec2 d = abs(p) - b;
        return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
      }

      float flick(float t, float s) {
        return 0.84 + 0.08 * sin(t * 5.3 + s) + 0.05 * sin(t * 12.1 + s * 2.0) + 0.07 * noise(vec2(t * 2.6, s));
      }

      // Mini-light colors: mostly warm 2700K incandescent with a few classic colored bulbs.
      vec3 bulbTint(float h) {
        if (h < 0.62) return vec3(1.0, 0.6, 0.26);
        if (h < 0.72) return vec3(1.0, 0.16, 0.08);
        if (h < 0.8) return vec3(0.25, 0.85, 0.3);
        if (h < 0.88) return vec3(0.3, 0.45, 1.0);
        return vec3(1.0, 0.42, 0.1);
      }

      // ---------- Defocused background ----------
      vec3 bokeh(vec2 p, float cell, float rmin, float rmax, float density, float seed, float t, float gain) {
        vec3 col = vec3(0.0);
        vec2 base = floor(p / cell);
        for (int j = -1; j <= 1; j++)
          for (int i = -1; i <= 1; i++) {
            vec2 id = base + vec2(i, j);
            float h = hash(id + seed);
            if (h > density) continue;
            vec2 c = (id + 0.5 + (vec2(hash(id + seed + 1.7), hash(id + seed + 4.1)) - 0.5) * 0.95) * cell;
            // Lights cluster on the tree (a cone at the right) and along garlands.
            // A blurred tree stands behind at the left; a garland runs along the far mantel.
            vec2 tq = c - vec2(-0.38, -0.55);
            float cone = smoothstep(0.02, -0.06, abs(tq.x) - (0.95 - tq.y) * 0.26) * step(0.0, tq.y);
            float garland = exp(-pow((c.y + 0.12 + 0.03 * cos(c.x * 9.0)) * 18.0, 2.0)) * step(c.x, 0.1);
            float keep = max(cone * 0.9, garland * 0.7) + 0.015;
            if (hash(id + seed + 9.3) > keep) continue;
            float r = mix(rmin, rmax, hash(id + seed + 2.9));
            vec2 d = p - c;
            float dist = length(d);
            float soft = r * 0.07 + 0.002;
            float disc = smoothstep(r, r - soft, dist);
            if (disc <= 0.0) continue;
            // Real lens bokeh: brighter rim, faint onion rings, slight cat-eye toward the frame edges.
            float rim = 0.72 + 0.38 * smoothstep(r * 0.45, r * 0.98, dist);
            float onion = 1.0 + 0.05 * sin(dist / r * 22.0 + h * 10.0);
            float cat = smoothstep(r * 1.4, r * 0.6, length(d + c * 0.05));
            float tw = 0.78 + 0.22 * sin(t * (0.25 + h * 0.9) + h * 40.0);
            col += bulbTint(fract(h * 7.13)) * disc * rim * onion * mix(1.0, cat, 0.5) * tw * gain;
          }
        return col;
      }

      vec3 background(vec2 p, float t, float warm) {
        vec3 c = mix(vec3(0.045, 0.016, 0.01), vec3(0.01, 0.006, 0.009), smoothstep(-0.55, 0.5, p.y));
        // Fireplace glow, far out of focus.
        float fl = flick(t, 1.0) * warm;
        c += vec3(1.0, 0.36, 0.09) * 0.42 * fl * exp(-length((p - vec2(-0.62, -0.42)) * vec2(0.85, 1.25)) * 2.4);
        c += vec3(1.0, 0.5, 0.15) * 0.25 * fl * exp(-length((p - vec2(-0.62, -0.36)) * vec2(1.4, 2.2)) * 5.0);
        // Window: cool moonlit snow, softly blurred.
        vec2 w = p - vec2(-0.05, 0.16);
        float win = smoothstep(0.06, -0.06, sdBox(w, vec2(0.15, 0.22)));
        float mull = smoothstep(0.03, 0.0, abs(w.x)) + smoothstep(0.03, 0.0, abs(w.y - 0.03));
        vec3 sky = mix(vec3(0.05, 0.08, 0.16), vec3(0.025, 0.04, 0.09), smoothstep(-0.2, 0.2, w.y));
        float snowFall = 0.0;
        for (int i = 0; i < 2; i++) {
          vec2 q = w * (14.0 + float(i) * 8.0) + vec2(sin(t * 0.2 + float(i)) * 0.5, t * (0.5 - float(i) * 0.12));
          vec2 id = floor(q);
          vec2 o = vec2(hash(id + 31.0), hash(id + 37.0)) * 0.5 + 0.25;
          snowFall += smoothstep(0.45, 0.0, length(fract(q) - o)) * step(0.75, hash(id + float(i) * 7.0)) * 0.12;
        }
        c = mix(c, sky + vec3(0.25, 0.3, 0.4) * snowFall * 0.4, win * (1.0 - 0.6 * clamp(mull, 0.0, 1.0)));
        vec2 tq2 = p - vec2(-0.38, -0.55);
        float treeSil = smoothstep(0.05, -0.05, abs(tq2.x) - (0.98 - tq2.y) * 0.27 + 0.02 * sin(tq2.y * 30.0)) * smoothstep(-0.02, 0.05, tq2.y) * smoothstep(1.0, 0.9, tq2.y);
        c = mix(c, vec3(0.012, 0.022, 0.014) + vec3(1.0, 0.6, 0.3) * 0.03, treeSil * 0.85);
        // Warm lamp in the far corner.
        c += vec3(1.0, 0.55, 0.22) * 0.07 * exp(-length(p - vec2(0.05, 0.05)) * 4.0);
        // Bokeh from distant lights, three depths.
        c += bokeh(p, 0.15, 0.05, 0.075, 0.9, 3.0, t, 0.08 * warm);
        c += bokeh(p, 0.075, 0.024, 0.036, 0.9, 11.0, t, 0.14 * warm);
        c += bokeh(p, 0.04, 0.01, 0.016, 0.85, 23.0, t, 0.22 * warm);
        return c;
      }

      // ---------- In-focus elements ----------
      const int BULBS = 18;
      vec2 bulbPos[BULBS];
      vec3 bulbColor[BULBS];

      vec2 sway(vec2 q, float t, float s) {
        return q + vec2(0.0018 * sin(t * 0.45 + s), 0.0014 * sin(t * 0.37 + s * 1.7)) * smoothstep(0.6, 0.95, abs(q.x) * 0.0 + 1.0);
      }

      // A pine twig with needles on both sides angled toward the tip.
      // Returns (coverage, shade); blur widens and softens it for depth of field.
      vec2 twig(vec2 p, vec2 a, vec2 b, float len, float blur, float seed) {
        vec2 ba = b - a;
        float L = length(ba);
        vec2 dir = ba / L;
        vec2 nrm = vec2(-dir.y, dir.x);
        vec2 q = vec2(dot(p - a, dir), dot(p - a, nrm));
        // Twigs bend slightly under their own weight.
        q.y += 0.08 * L * (q.x / L) * (1.0 - q.x / L);
        if (q.x < -0.01 || q.x > L + len || abs(q.y) > len + blur + 0.004) return vec2(0.0);
        float best = 0.0;
        float shade = 0.0;
        float stemW = 0.0013 * (1.2 - 0.5 * clamp(q.x / L, 0.0, 1.0));
        float stem = smoothstep(stemW + blur + 0.0005, stemW - 0.0005, abs(q.y)) * step(0.0, q.x) * step(q.x, L);
        if (stem > 0.0) {
          best = stem;
          shade = 0.35;
        }
        float spacing = 0.0026;
        float side = q.y >= 0.0 ? 1.0 : -1.0;
        float ang = 0.95;
        float cotA = cos(ang) / sin(ang);
        float x0 = q.x - abs(q.y) * cotA;
        float k0 = floor(x0 / spacing);
        for (int k = -3; k <= 3; k++) {
          float idx = k0 + float(k);
          float px0 = idx * spacing;
          if (px0 < 0.0 || px0 > L) continue;
          float h = hash(vec2(idx, seed + side * 3.1));
          float h2 = hash(vec2(idx, seed + side * 5.7));
          float a2 = ang + (h - 0.5) * 0.5;
          // Foreshortening: needles pointing toward or away from the camera look shorter.
          float nl = len * (0.45 + 0.55 * h2) * (1.0 - 0.45 * smoothstep(0.75, 1.0, px0 / L));
          vec2 base = vec2(px0, 0.0);
          vec2 tip = base + vec2(cos(a2), side * sin(a2)) * nl;
          // Needles curve gently.
          vec2 mid = (base + tip) * 0.5 + vec2(-side, 1.0).yx * 0.0 + vec2(0.0, side * nl * 0.06);
          vec2 pa = q - base;
          vec2 ta = tip - base;
          float s = clamp(dot(pa, ta) / dot(ta, ta), 0.0, 1.0);
          vec2 closest = base + ta * s + vec2(0.0, side * nl * 0.12 * s * (1.0 - s));
          float d = length(q - closest);
          float w = 0.00085 * (1.0 - 0.75 * s) + 0.0002;
          float cov = smoothstep(w + blur + 0.0006, w - 0.0003, d);
          if (cov > best) {
            best = cov;
            // Light catches along one edge of the flattened needle.
            float edgeLit = 0.5 + 0.5 * clamp((dot(q - closest, vec2(-ta.y, ta.x) / length(ta)) * side) / max(w, 1e-4), -1.0, 1.0);
            shade = (0.35 + 0.65 * s) * (0.55 + 0.45 * h) * (0.6 + 0.6 * edgeLit);
          }
        }
        return vec2(best, shade);
      }

      void addTwig(inout vec3 c, inout float occl, vec2 p, vec2 a, vec2 b, float len, float blur, float seed, float t, vec3 lightAt, float far) {
        vec2 tw = twig(p, a, b, len, blur, seed);
        if (tw.x <= 0.0) return;
        vec3 needle = mix(vec3(0.006, 0.026, 0.014), vec3(0.03, 0.085, 0.045), tw.y);
        vec3 lit = needle * (0.25 + lightAt * 4.0) + vec3(1.0, 0.7, 0.4) * pow(tw.y, 6.0) * lightAt * 0.9;
        lit = mix(lit, c * 0.25 + vec3(0.01, 0.006, 0.005), far);
        c = mix(c, lit, tw.x);
        occl = max(occl, tw.x);
      }

      vec3 bulbLight(vec2 p) {
        vec3 l = vec3(0.0);
        for (int i = 0; i < BULBS; i++) {
          float d = length(p - bulbPos[i]);
          l += bulbColor[i] * (0.12 * exp(-d * 28.0) + 0.5 * exp(-d * 90.0));
        }
        return l;
      }

      // A mirrored glass bauble that reflects the room and the nearby bulbs.
      void bauble(inout vec3 c, vec2 p, vec2 center, float r, vec3 tint, float kind, float t, float warm, float px, vec2 hook) {
        vec2 hq = p - center;
        // Thin wire hook up to the branch.
        vec2 top = vec2(0.0, r * 1.15);
        vec2 hd = hook - center;
        float hs = clamp(dot(hq - top, hd - top) / dot(hd - top, hd - top), 0.0, 1.0);
        float hw = length(hq - top - (hd - top) * hs);
        c = mix(c, vec3(0.35, 0.28, 0.18) * (0.4 + warm * 0.4), smoothstep(0.0011, 0.0003, hw));
        vec2 d = hq / r;
        float dd = dot(d, d);
        // Metal cap with ridges.
        vec2 cq = hq - vec2(0.0, r * 0.98);
        if (abs(cq.x) < r * 0.22 && cq.y > 0.0 && cq.y < r * 0.16) {
          float ridge = 0.6 + 0.4 * sin(cq.x / r * 90.0);
          float sheen = smoothstep(r * 0.22, -r * 0.05, abs(cq.x + r * 0.07));
          c = vec3(0.75, 0.58, 0.3) * (0.15 + 0.9 * sheen) * ridge * (0.5 + warm * 0.4);
        }
        if (dd > 1.0 + px * 6.0 / r) return;
        float alpha = smoothstep(1.0, 1.0 - px * 2.5 / r, sqrt(dd));
        vec3 n = vec3(d, sqrt(max(1.0 - dd, 0.0)));
        vec3 R = reflect(vec3(0.0, 0.0, -1.0), n);
        // The sphere sees a wide, distorted view of the room behind the camera and around it.
        vec2 envP = center * 0.35 + R.xy * 0.75;
        vec3 env = mix(vec3(0.09, 0.035, 0.018), vec3(0.015, 0.01, 0.012), smoothstep(-0.6, 0.6, envP.y));
        env += vec3(1.0, 0.45, 0.12) * 0.25 * exp(-length(envP - vec2(-0.5, -0.4)) * 3.0) * warm;
        float fres = 0.25 + 0.75 * pow(1.0 - n.z, 3.0);
        vec3 col;
        if (kind < 0.5) {
          // Glossy colored glass.
          col = tint * 0.06 * (0.4 + 0.6 * n.z) + env * mix(tint * 1.8, vec3(1.0), fres * 0.55);
        } else if (kind < 1.5) {
          // Satin gold with fine glitter.
          col = tint * (0.08 + 0.25 * max(dot(n, normalize(vec3(-0.4, 0.5, 0.8))), 0.0)) + env * tint * 0.9;
          vec2 g = floor(p / max(px, 0.0006));
          float sp = step(0.993, hash(g + floor(t * 2.0))) * 0.5;
          col += vec3(1.0, 0.85, 0.55) * sp * 2.0 * n.z * warm;
        } else {
          // Silver mirror.
          col = env * tint * 1.5 + tint * 0.02;
        }
        // Sharp reflections of each nearby bulb and a soft window highlight.
        for (int i = 0; i < BULBS; i++) {
          vec3 L = normalize(vec3(bulbPos[i] - center, 0.09));
          vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
          float dist = length(bulbPos[i] - center);
          if (dist > 0.16) continue;
          col += bulbColor[i] * pow(max(dot(n, H), 0.0), 300.0) * 4.0 * smoothstep(0.16, 0.04, dist);
        }
        vec2 win = n.xy - vec2(-0.42, 0.42);
        col += vec3(0.4, 0.5, 0.75) * 0.5 * smoothstep(0.16, 0.08, sdBox(win, vec2(0.07, 0.11)));
        col += vec3(1.0, 0.92, 0.8) * pow(max(dot(n, normalize(vec3(-0.35, 0.45, 0.82))), 0.0), 250.0) * 3.0;
        // Contact darkening at the silhouette.
        col *= 0.55 + 0.45 * smoothstep(1.0, 0.7, dd);
        c = mix(c, col, alpha);
      }

      void main() {
        vec2 p = (gl_FragCoord.xy - resolution * 0.5) / resolution.y;
        float t = time;
        float px = 1.0 / resolution.y;
        float warm = 1.0 + 0.3 * breath;
        float aspect = resolution.x / resolution.y;
        float R = aspect * 0.5;

        // Six main boughs reach in from the right edge; lights sit along them.
        vec2 bA[6];
        vec2 bB[6];
        float bFar[6];
        for (int k = 0; k < 6; k++) {
          float fk = float(k);
          float y = 0.52 - fk * 0.2 + 0.04 * sin(fk * 2.3);
          vec2 sw = sway(vec2(0.0), t, fk);
          bA[k] = vec2(R + 0.05, y + 0.05) + sw * 0.4;
          float len = 0.62 + 0.16 * hash(vec2(fk, 5.0));
          bB[k] = bA[k] + vec2(-len, -0.08 - 0.05 * hash(vec2(fk, 6.0))) + sw;
          bFar[k] = mod(fk, 2.0) * 0.35;
        }
        for (int i = 0; i < BULBS; i++) {
          int k = i / 3;
          float u = 0.28 + float(i - k * 3) * 0.25 + 0.06 * hash(vec2(float(i), 3.0));
          vec2 pos = mix(bA[k], bB[k], u);
          pos.y += 0.08 * u * (1.0 - u) * -0.5 + (hash(vec2(float(i), 9.0)) - 0.5) * 0.04;
          bulbPos[i] = pos;
          float h = hash(vec2(float(i), 71.0));
          float tw = 0.86 + 0.14 * sin(t * (0.35 + h) + h * 30.0);
          bulbColor[i] = bulbTint(fract(h * 3.7 + 0.2)) * tw * warm * (1.0 - bFar[k] * 0.8);
        }

        vec3 c = background(p, t, warm);
        vec3 lightAt = bulbLight(p);
        float occl = 0.0;

        // Back layer of boughs first, then the front layer.
        for (int pass = 0; pass < 2; pass++) {
          for (int k = 0; k < 6; k++) {
            float far = bFar[k];
            if ((pass == 0) != (far > 0.0)) continue;
            vec2 a = bA[k];
            vec2 b = bB[k];
            vec2 mn = min(a, b) - 0.2;
            vec2 mx = max(a, b) + 0.2;
            if (p.x < mn.x || p.y < mn.y || p.x > mx.x || p.y > mx.y) continue;
            float fk = float(k);
            vec3 la = lightAt * (1.0 - far);
            float blur = far * 0.006;
            float darken = far;
            addTwig(c, occl, p, a, b, 0.05, blur, fk * 13.0, t, la, darken);
            for (int j = 0; j < 8; j++) {
              float fj = float(j);
              float u = 0.08 + fj * 0.115;
              vec2 o = mix(a, b, u);
              vec2 dir = normalize(b - a);
              float side = mod(fj, 2.0) * 2.0 - 1.0;
              float ang = side * (0.6 + 0.25 * hash(vec2(fk, fj)));
              vec2 d2 = mat2(cos(ang), -sin(ang), sin(ang), cos(ang)) * dir;
              float ln = (0.17 + 0.09 * hash(vec2(fj, fk + 3.0))) * (1.15 - u * 0.6);
              addTwig(c, occl, p, o, o + d2 * ln, 0.04, blur, fk * 13.0 + fj + 1.0, t, la, darken);
            }
          }
        }

        // Baubles hanging from the front boughs.
        for (int k = 0; k < 6; k += 2) {
          float fk = float(k);
          vec2 hook = mix(bA[k], bB[k], 0.55 + 0.08 * fk / 2.0);
          float r = 0.05 - fk * 0.004;
          vec2 cen = hook - vec2(0.0, 0.075 + 0.02 * hash(vec2(fk, 1.0)));
          cen.x += 0.004 * sin(t * 0.6 + fk);
          vec3 tint = k == 0 ? vec3(0.62, 0.03, 0.05) : (k == 2 ? vec3(0.95, 0.7, 0.32) : vec3(0.85, 0.88, 0.95));
          bauble(c, p, cen, r, tint, k == 0 ? 0.0 : (k == 2 ? 1.0 : 2.0), t, warm, px, hook);
        }

        // Wires and bulbs.
        for (int i = 0; i < BULBS - 1; i++) {
          vec2 a = bulbPos[i];
          vec2 b = bulbPos[i + 1];
          if ((i + 1) / 3 != i / 3) continue;
          vec2 ba = b - a;
          float s = clamp(dot(p - a, ba) / dot(ba, ba), 0.0, 1.0);
          float d = length(p - a - ba * s - vec2(0.0, -0.05 * s * (1.0 - s)));
          c = mix(c, vec3(0.008, 0.025, 0.012) + lightAt * 0.04, smoothstep(0.0013, 0.0004, d));
        }
        for (int i = 0; i < BULBS; i++) {
          vec2 q = p - bulbPos[i];
          if (dot(q, q) > 0.04) continue;
          float h = hash(vec2(float(i), 71.0));
          float ang = (h - 0.5) * 1.4;
          q = mat2(cos(ang), -sin(ang), sin(ang), cos(ang)) * q;
          if (abs(q.x) < 0.0034 && q.y > 0.0 && q.y < 0.007) c = vec3(0.015, 0.05, 0.022) + bulbColor[i] * 0.12;
          float env = length((q - vec2(0.0, -0.007)) * vec2(1.0, 0.55)) - 0.0042;
          vec3 bc = bulbColor[i];
          if (env < 0.0) c = bc * (1.4 + 2.4 * smoothstep(0.0, -0.004, env));
          c += mix(bc, vec3(1.0, 0.95, 0.85), 0.6) * 5.0 * exp(-length(q - vec2(0.0, -0.007)) * 900.0);
          c += bc * (0.3 * exp(-length(q) * 140.0) + 0.05 * exp(-length(q) * 35.0));
        }

        // Dust motes drifting through the light.
        for (int i = 0; i < 14; i++) {
          float fi = float(i);
          vec2 m = vec2(hash(vec2(fi, 1.0)) * 1.6 - 0.8, fract(hash(vec2(fi, 2.0)) - t * (0.004 + 0.006 * hash(vec2(fi, 3.0)))) - 0.5);
          m.x += 0.02 * sin(t * 0.2 + fi * 2.0);
          float sz = 0.003 + 0.006 * hash(vec2(fi, 4.0));
          c += vec3(1.0, 0.75, 0.45) * smoothstep(sz, sz * 0.4, length(p - m)) * 0.04 * (0.5 + 0.5 * sin(t * 0.7 + fi)) * warm;
        }

        c *= 1.0 - 0.5 * smoothstep(0.5, 1.1, length(p * vec2(0.75, 1.15)));
        // Gentle film grain.
        c += (hash(gl_FragCoord.xy + fract(t) * 100.0) - 0.5) * 0.012;
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
      fail(new Error("The graphics context was lost. Select another theme and return to Christmas."));
    });
    draw(0);
    diagnostics.status = "ready";
    notify();
  } catch (error) {
    fail(error);
  }
})();
