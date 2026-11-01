"use strict";

(() => {
  const canvas = document.querySelector("#universe");
  const diagnostics = { status: "loading", error: null, frames: 0, paused: true, time: 0 };
  window.__rain = diagnostics;

  function notify() {
    window.webkit?.messageHandlers?.rain?.postMessage({
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
    if (!gl) throw new Error("Rainy window requires WebGL 2, which is unavailable on this Mac.");
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

      float skylineAt(float x) {
        return 0.05 + 0.28 * pow(noise(vec2(floor(x * 9.0) * 1.7, 2.0)), 1.4) + 0.12 * noise(vec2(x * 2.0, 5.0));
      }

      vec2 hash2(vec2 p) { return vec2(hash(p), hash(p + 17.31)); }

      // Soft camera bokeh: a disc whose edge softens and rim brightens as blur grows.
      float bokeh(float d, float r, float px) {
        float edge = max(px * 1.5, r * 0.12);
        float disc = smoothstep(r, r - edge, d);
        float halo = exp(-max(d - r, 0.0) / (r * 0.35 + px)) * 0.12 * (1.0 - disc);
        return disc * (0.82 + 0.3 * smoothstep(r * 0.45, r, d)) + halo;
      }

      vec3 lights(vec2 p, float cell, float yMin, float yMax, float density, float r0, float r1, float blur, float seed, float px, float t, int palette) {
        vec3 c = vec3(0);
        vec2 g = p / cell;
        vec2 id0 = floor(g);
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
          vec2 id = id0 + vec2(i, j);
          vec2 key = id + seed;
          if (hash(key) > density) continue;
          vec2 pos = (id + 0.2 + 0.6 * hash2(key + 3.0)) * cell;
          if (pos.y < yMin || pos.y > yMax || (palette == 0 && pos.y > skylineAt(pos.x) - 0.01)) continue;
          float r = mix(r0, r1, blur) * (0.75 + 0.5 * hash(key + 5.0));
          float k = hash(key + 7.0);
          vec3 col = palette == 0
            ? (k < 0.5 ? vec3(1.0, 0.55, 0.22) : k < 0.78 ? vec3(0.55, 0.75, 1.0) : k < 0.9 ? vec3(1.0, 0.82, 0.5) : vec3(0.4, 1.0, 0.85))
            : (k < 0.5 ? vec3(1.0, 0.45, 0.12) : vec3(1.0, 0.7, 0.35));
          float energy = pow(r0 / r, 1.25);
          float flick = 0.85 + 0.15 * sin(t * (0.5 + hash(key + 9.0)) + k * 40.0);
          c += col * bokeh(length(p - pos), r, px) * energy * flick * (0.35 + 0.65 * hash(key + 11.0));
        }
        return c;
      }

      vec3 traffic(vec2 p, float y, float dir, float speed, float blur, float seed, float px, float t) {
        vec3 c = vec3(0);
        float cell = 0.34;
        float x = p.x - dir * speed * t;
        float id0 = floor(x / cell);
        for (int i = -1; i <= 1; i++) {
          float id = id0 + float(i);
          if (hash(vec2(id, seed)) < 0.35) continue;
          float cx = (id + 0.2 + 0.6 * hash(vec2(id, seed + 2.0))) * cell;
          float r = mix(0.004, 0.034, blur);
          float energy = pow(0.004 / r, 1.2);
          vec3 col = dir > 0.0 ? vec3(1.0, 0.92, 0.78) * 1.5 : vec3(1.0, 0.08, 0.05);
          for (int k = 0; k < 2; k++) {
            vec2 lp = vec2(cx + (float(k) - 0.5) * 0.022, y);
            c += col * bokeh(length(vec2(x, p.y) - lp), r, px) * energy;
          }
        }
        return c;
      }

      vec3 city(vec2 p, float blur, float t, float px) {
        float glow = 1.0 + 0.25 * breath;
        vec3 c = mix(vec3(0.05, 0.035, 0.05), vec3(0.008, 0.012, 0.030), smoothstep(-0.25, 0.5, p.y));
        c += vec3(0.25, 0.12, 0.08) * 0.35 * exp(-abs(p.y + 0.14) * 7.0);
        float soft = mix(0.004, 0.09, blur);
        float skyline = skylineAt(p.x);
        float mass = smoothstep(skyline + soft, skyline - soft, p.y) * smoothstep(-0.32, -0.12, p.y);
        c = mix(c, vec3(0.02, 0.022, 0.035), mass * 0.7);
        vec3 l = vec3(0);
        l += lights(p, 0.036, -0.12, 0.4, 0.3, 0.0035, 0.024, blur, 1.0, px, t, 0) * 1.3;
        l += lights(p, 0.11, -0.16, -0.02, 0.6, 0.006, 0.055, blur, 9.0, px, t, 1) * 1.8;
        l += traffic(p, -0.215, 1.0, 0.07, blur, 3.0, px, t);
        l += traffic(p, -0.245, -1.0, 0.055, blur, 7.0, px, t);
        l += traffic(p, -0.235, 1.0, 0.105, blur, 13.0, px, t) * 0.8;
        // A pink neon sign and a slowly cycling traffic signal.
        vec2 sq = abs(p - vec2(-0.42, 0.06)) - vec2(0.06, 0.012);
        float sd = length(max(sq, 0.0)) + min(max(sq.x, sq.y), 0.0);
        l += vec3(1.0, 0.2, 0.55) * smoothstep(soft * 0.6 + 0.002, -soft * 0.6, sd) * 0.9 * (0.9 + 0.1 * step(0.05, fract(t * 0.37)));
        float phase = fract(t / 24.0);
        vec3 signal = phase < 0.45 ? vec3(0.2, 1.0, 0.45) : phase < 0.55 ? vec3(1.0, 0.65, 0.1) : vec3(1.0, 0.1, 0.06);
        l += signal * bokeh(length(p - vec2(0.36, -0.12)), mix(0.004, 0.04, blur), px) * pow(0.004 / mix(0.004, 0.04, blur), 1.1) * 2.0;
        // Reflections on the wet street below.
        float wet = smoothstep(-0.25, -0.32, p.y);
        c += l * glow * 2.3;
        // Smeared reflections of the traffic on the wet road.
        vec2 rp = vec2(p.x, -0.23 + (-0.23 - p.y) * 0.35);
        float smear = mix(0.6, 1.0, blur);
        vec3 refl = traffic(rp, -0.215, 1.0, 0.07, smear, 3.0, px, t) + traffic(rp, -0.245, -1.0, 0.055, smear, 7.0, px, t);
        c += refl * wet * 0.35 * (0.7 + 0.3 * noise(vec2(p.x * 40.0, p.y * 6.0)));
        c += vec3(0.35, 0.2, 0.15) * 0.1 * wet * (0.6 + 0.4 * noise(vec2(p.x * 30.0, t * 0.2)));
        return c;
      }

      // Rain on the glass: beads, sliding drops with stick-slip motion, and wiped trails.
      float drops(vec2 p, float t, out vec2 n, out float wiped) {
        n = vec2(0);
        wiped = 0.0;
        float mask = 0.0;
        for (int layer = 0; layer < 2; layer++) {
          float W = layer == 0 ? 0.075 : 0.045;
          float col = floor(p.x / W);
          vec2 key = vec2(col, float(layer) * 31.0);
          if (hash(key) < 0.3) continue;
          float period = (layer == 0 ? 7.0 : 11.0) + 9.0 * hash(key + 1.0);
          float u = fract(t / period + hash(key + 2.0));
          float steps = 5.0 + floor(5.0 * hash(key + 3.0));
          float slip = (floor(u * steps) + smoothstep(0.55, 1.0, fract(u * steps))) / steps;
          float y = 0.62 - 1.3 * mix(u, slip, 0.75);
          float rd = W * (0.15 + 0.08 * hash(key + 4.0));
          float x = (col + 0.3 + 0.4 * hash(key + 5.0)) * W + 0.006 * sin(y * 30.0 + hash(key) * 6.0) * hash(key + 6.0);
          vec2 q = p - vec2(x, y);
          q.y *= q.y > 0.0 ? 0.62 : 1.05;
          float d = length(q);
          if (d < rd) {
            float h = sqrt(1.0 - d * d / (rd * rd));
            n += q / rd * (1.0 - h * 0.3);
            mask = max(mask, smoothstep(rd, rd - 0.0015, d));
          }
          float above = p.y - y;
          if (above > 0.0) {
            float trailX = x + 0.006 * sin((p.y) * 30.0 + hash(key) * 6.0) * hash(key + 6.0) - x;
            float dx = abs(p.x - (x + trailX));
            wiped = max(wiped, smoothstep(rd * 1.5, rd * 0.3, dx) * exp(-above * 1.6));
            // Residue droplets left in the trail.
            float s = 0.014;
            float idy = floor((p.y - y) / s);
            float present = step(0.45, hash(vec2(idy, col) + float(layer) * 7.0)) * exp(-above * 2.5);
            vec2 rq = vec2(p.x - (x + trailX) - (hash(vec2(idy, col + 3.0)) - 0.5) * rd * 0.5, mod(p.y - y, s) - s * 0.5);
            float rr = rd * (0.22 + 0.15 * hash(vec2(idy, col + 9.0))) * present;
            float rdd = length(rq);
            if (rdd < rr) {
              n += rq / rr * 0.8;
              mask = max(mask, smoothstep(rr, rr - 0.001, rdd));
            }
          }
        }
        // Small static beads that fade in and are cleared by passing trails.
        for (int s = 0; s < 2; s++) {
          float scale = s == 0 ? 34.0 : 70.0;
          vec2 g = p * scale + float(s) * 13.7;
          vec2 id = floor(g), f = fract(g) - 0.5;
          vec2 c = (hash2(id + float(s) * 5.0) - 0.5) * 0.55;
          float r = (0.1 + 0.26 * pow(hash(id + 4.4 + float(s)), 2.0));
          float life = fract(t / (35.0 + 30.0 * hash(id + 1.9)) + hash(id + 2.7));
          r *= smoothstep(0.0, 0.25, life) * step(s == 0 ? 0.45 : 0.62, hash(id + 6.6));
          vec2 q = f - c;
          q.y *= 1.12;
          float d = length(q);
          if (d < r) {
            float keep = 1.0 - wiped;
            n += q / r * keep;
            mask = max(mask, smoothstep(r, r - 0.06, d) * keep);
          }
        }
        return mask;
      }

      void main() {
        vec2 p = (gl_FragCoord.xy - resolution * 0.5) / resolution.y;
        float t = time;
        float px = 1.0 / resolution.y;
        vec2 n;
        float wiped;
        float m = drops(p, t, n, wiped);
        float fog = clamp(0.62 + 0.45 * (fbm(p * 2.6 + 4.0) - 0.5) + 0.25 * smoothstep(-0.2, -0.55, p.y), 0.0, 1.0);
        float blur = mix(1.0, 0.06, m);
        vec2 lens = -n * 0.11 * m;
        vec3 c = city(p + lens, blur, t, px);
        // Condensation scatters light into a soft milky haze.
        vec3 haze = vec3(0.045, 0.042, 0.06) + vec3(0.25, 0.14, 0.12) * 0.2 * exp(-abs(p.y + 0.14) * 4.0);
        c = mix(c, haze + c * 0.75, fog * 0.32 * (1.0 - wiped * 0.5) * (1.0 - m));
        // Drop rims darken and catch a highlight from the room.
        float rim = smoothstep(0.55, 1.0, length(n)) * m;
        c *= 1.0 - rim * 0.3;
        c += vec3(0.05, 0.05, 0.07) * m;
        c += vec3(1.0, 0.75, 0.55) * pow(max(dot(normalize(n + 1e-4), normalize(vec2(0.3, -0.9))), 0.0), 6.0) * m * 0.12;
        c += vec3(1.0, 0.85, 0.7) * pow(max(dot(normalize(n + 1e-4), normalize(vec2(-0.55, 0.8))), 0.0), 12.0) * m * 0.8;
        c += vec3(0.55, 0.32, 0.16) * 0.07 * exp(-length(p - vec2(-0.95, -0.6)) * 1.8) * (1.0 + 0.4 * breath);
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
      gl.uniform1f(composite.uniform("strength"), 0.68);
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
      fail(new Error("The graphics context was lost. Select another theme and return to Rainy window."));
    });
    draw(0);
    diagnostics.status = "ready";
    notify();
  } catch (error) {
    fail(error);
  }
})();
