"use strict";

(() => {
  const canvas = document.querySelector("#universe");
  const diagnostics = { status: "loading", error: null, frames: 0, paused: true, time: 0 };
  window.__aurora = diagnostics;

  function notify() {
    window.webkit?.messageHandlers?.aurora?.postMessage({
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
    if (!gl) throw new Error("Aurora requires WebGL 2, which is unavailable on this Mac.");
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

      const float HORIZON = -0.06;

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
      float ridge1(float x, float seed) {
        float n = 0.0, a = 0.5, f = 1.0;
        for (int i = 0; i < 5; i++) {
          n += a * (1.0 - abs(noise(vec2(x * f, seed + float(i) * 7.1)) * 2.0 - 1.0));
          a *= 0.48; f *= 2.1;
        }
        return n;
      }

      // Two sweeping arcs of curtains with drifting rays and travelling brightness waves.
      float curtain(vec2 q, float t) {
        float x = q.x;
        float warp = fbm(vec2(x * 0.045 + t * 0.018, t * 0.012)) - 0.5;
        float z1 = 10.5 + 2.5 * sin(x * 0.075 + t * 0.045) + warp * 10.0;
        float z2 = 21.0 + 5.0 * sin(x * 0.052 - t * 0.032 + 1.7) + warp * 13.0;
        float w1 = 0.32 + 0.55 * noise(vec2(x * 0.12, t * 0.08));
        float a = exp(-pow((q.y - z1) / w1, 2.0));
        float b = 0.6 * exp(-pow((q.y - z2) / 0.9, 2.0));
        float rays = 0.18 + 1.25 * pow(noise(vec2(x * 1.6 + warp * 7.0, t * 0.35)), 2.6) + 0.5 * pow(noise(vec2(x * 4.5 - t * 0.6, 3.0)), 3.0);
        float pulse = 0.72 + 0.28 * sin(x * 0.11 - t * 0.55 + warp * 9.0);
        return (a + b) * rays * pulse;
      }

      vec3 aurora(vec3 rd, float t, int steps, float dither) {
        vec3 acc = vec3(0);
        if (rd.y < 0.012) return acc;
        float glow = 1.0 + 1.1 * breath;
        for (int i = 0; i < 44; i++) {
          if (i >= steps) break;
          float fi = (float(i) + dither) / float(steps);
          float h = 1.6 + fi * fi * 5.5;
          float dist = h / rd.y;
          if (dist > 90.0) break;
          vec2 q = rd.xz * dist;
          float d = curtain(q, t);
          float lower = smoothstep(0.0, 0.06, fi);
          float fade = exp(-fi * 3.2);
          vec3 green = vec3(0.12, 1.0, 0.52);
          vec3 teal = vec3(0.05, 0.75, 0.85);
          vec3 violet = vec3(0.62, 0.22, 1.0);
          vec3 rose = vec3(1.0, 0.25, 0.55);
          vec3 col = mix(green, teal, smoothstep(0.05, 0.3, fi));
          col = mix(col, violet, smoothstep(0.28, 0.65, fi));
          col = mix(col, rose, smoothstep(0.7, 1.0, fi) * 0.6);
          float shimmer = 0.75 + 0.25 * sin(t * 1.7 + q.x * 0.35 + fi * 6.0);
          acc += col * d * lower * (fade + 0.08) * shimmer;
        }
        float distanceFade = smoothstep(0.012, 0.14, rd.y);
        return acc * distanceFade * glow * (11.0 / float(steps));
      }

      vec3 stars(vec2 p, float t) {
        vec3 c = vec3(0);
        for (int layer = 0; layer < 2; layer++) {
          float scale = layer == 0 ? 120.0 : 260.0;
          vec2 g = p * scale;
          vec2 cell = floor(g), f = fract(g);
          float h = hash(cell + float(layer) * 41.0);
          if (h > 0.965) {
            vec2 offset = vec2(hash(cell + 3.1), hash(cell + 7.7)) * 0.7 + 0.15;
            vec2 delta = f - offset;
            float size = mix(0.05, 0.12, pow(hash(cell + 9.2), 4.0)) * (layer == 0 ? 1.0 : 0.7);
            float star = exp(-dot(delta, delta) / (size * size));
            float twinkle = 0.55 + 0.45 * sin(t * (1.5 + 3.0 * hash(cell + 1.3)) + h * 50.0);
            vec3 tint = mix(vec3(0.65, 0.78, 1.0), vec3(1.0, 0.86, 0.7), hash(cell + 4.4));
            c += star * tint * twinkle * mix(0.25, 1.6, pow(hash(cell + 2.2), 3.0));
          }
        }
        return c;
      }

      vec3 skyColor(vec3 rd, vec2 p, float t, int steps, float dither, bool withStars) {
        float y = max(rd.y, 0.0);
        vec3 c = mix(vec3(0.018, 0.045, 0.075), vec3(0.004, 0.008, 0.024), pow(y, 0.45));
        c += vec3(0.02, 0.06, 0.06) * exp(-y * 9.0);
        if (withStars) {
          vec2 band = vec2(p.x * 0.8 + p.y * 0.55, p.y - p.x * 0.4);
          float milky = exp(-pow(band.y * 3.2 - 0.6, 2.0)) * fbm(band * 6.0 + 2.0);
          c += vec3(0.035, 0.03, 0.05) * milky * smoothstep(0.0, 0.25, y);
          c += stars(p, t) * smoothstep(0.0, 0.08, y) * 0.9;
        }
        c += aurora(rd, t, steps, dither);
        return c;
      }

      float mountains(float x, out float far) {
        far = HORIZON + 0.03 + 0.15 * pow(ridge1(x * 1.25 + 4.0, 3.0), 2.4);
        float shore = smoothstep(0.05, 0.75, abs(x + 0.08));
        float hill = HORIZON - 0.004 + 0.07 * shore * (0.6 + 0.4 * noise(vec2(x * 4.0, 1.0)));
        float trees = 0.0;
        for (int k = 0; k < 2; k++) {
          float width = k == 0 ? 0.011 : 0.0065;
          float cx = x / width + float(k) * 0.37;
          float cell = floor(cx), f = fract(cx);
          float tall = (k == 0 ? 0.04 : 0.022) * (0.45 + 0.55 * hash(vec2(cell, float(k))));
          float spike = tall * max(0.0, 1.0 - abs(f - 0.5) * 2.3);
          trees = max(trees, spike * step(0.18, hash(vec2(cell, 9.0 + float(k)))) * (0.25 + shore));
        }
        return hill + trees;
      }

      vec3 shootingStar(vec2 p, float t) {
        float period = 9.0;
        float id = floor(t / period);
        float local = t - id * period;
        if (local > 0.9 || hash(vec2(id, 3.0)) < 0.35) return vec3(0);
        vec2 start = vec2(mix(-0.7, 0.5, hash(vec2(id, 1.0))), mix(0.2, 0.45, hash(vec2(id, 2.0))));
        vec2 dir = normalize(vec2(0.9, -0.42 - 0.3 * hash(vec2(id, 4.0))));
        vec2 head = start + dir * local * 0.6;
        vec2 rel = p - head;
        float along = dot(rel, -dir);
        float across = abs(dot(rel, vec2(-dir.y, dir.x)));
        float tail = smoothstep(0.22, 0.0, along) * step(0.0, along + 0.004);
        float life = sin(local / 0.9 * 3.14159);
        return vec3(0.85, 0.92, 1.0) * exp(-across * across * 2.0e5) * tail * life * 3.0;
      }

      void main() {
        vec2 p = (gl_FragCoord.xy - resolution * 0.5) / resolution.y;
        float t = time;
        float dither = hash(gl_FragCoord.xy + fract(t) * 13.0);
        vec3 ambient = vec3(0.05, 0.32, 0.22) * (0.8 + 0.6 * breath);
        vec3 c;
        float far;
        float near = mountains(p.x, far);
        if (p.y > HORIZON) {
          vec3 rd = normalize(vec3(p.x, p.y - HORIZON + 0.02, 1.15));
          c = skyColor(rd, p, t, 40, dither, true);
          c += shootingStar(p, t);
          if (p.y < far) {
            float depth = far - p.y;
            vec3 rock = mix(vec3(0.045, 0.07, 0.095), vec3(0.012, 0.02, 0.032), smoothstep(0.0, 0.11, depth));
            float streak = smoothstep(0.6, 0.85, noise(vec2(p.x * 55.0 + depth * 140.0, depth * 9.0)));
            rock += vec3(0.10, 0.16, 0.19) * streak * exp(-depth * 22.0);
            rock += ambient * 0.55 * exp(-depth * 110.0);
            c = mix(rock, c, 0.08 + 0.25 * exp(-(far - HORIZON) * 0.0));
            c = mix(c, vec3(0.02, 0.05, 0.065), exp(-(p.y - HORIZON) * 22.0) * 0.6);
          }
          if (p.y < near) {
            c = vec3(0.003, 0.005, 0.008) + ambient * 0.06 * exp(-(near - p.y) * 200.0);
          }
        } else {
          // Lake: mirror the scene with depth-scaled ripples and Fresnel.
          float below = HORIZON - p.y;
          float persp = 1.0 / (below + 0.02);
          vec2 wave = vec2(
            fbm(vec2(p.x * persp * 0.9, persp * 1.6 + t * 0.35)),
            fbm(vec2(p.x * persp * 0.7 + 3.0, persp * 1.2 - t * 0.28))) - 0.5;
          vec2 mp = vec2(p.x + wave.x * 0.012 * below * 8.0, HORIZON + below + wave.y * 0.02 * below * 6.0);
          vec3 rd = normalize(vec3(mp.x, mp.y - HORIZON + 0.02, 1.15));
          vec3 refl = skyColor(rd, mp, t, 18, dither, true);
          float rFar;
          float rNear = mountains(mp.x, rFar);
          if (mp.y < rFar) refl = mix(vec3(0.03, 0.05, 0.07), vec3(0.012, 0.02, 0.03), smoothstep(0.0, 0.11, rFar - mp.y)) + ambient * 0.2 * exp(-(rFar - mp.y) * 110.0);
          if (mp.y < rNear) refl = vec3(0.003, 0.005, 0.008);
          float fresnel = mix(0.32, 0.85, exp(-below * 9.0));
          vec3 water = vec3(0.004, 0.012, 0.018);
          c = mix(water, refl, fresnel);
          float sparkle = pow(noise(vec2(p.x * 260.0, persp * 30.0 + t * 0.8)), 22.0) * exp(-below * 4.0);
          c += vec3(0.4, 0.9, 0.75) * sparkle * 0.35 * (0.6 + breath);
        }
        float mist = fbm(vec2(p.x * 2.4 + t * 0.03, (p.y - HORIZON) * 18.0 - t * 0.02));
        c += (vec3(0.06, 0.12, 0.13) + ambient * 0.25) * mist * exp(-abs(p.y - HORIZON + 0.005) * 28.0) * 0.55;
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

    // Breathing guide: the aurora brightens for 5s (inhale), then dims for 5s.
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
      fail(new Error("The graphics context was lost. Select another theme and return to Aurora."));
    });
    draw(0);
    diagnostics.status = "ready";
    notify();
  } catch (error) {
    fail(error);
  }
})();
