"use strict";

(() => {
  const canvas = document.querySelector("#universe");
  const diagnostics = { status: "loading", error: null, frames: 0, paused: true, time: 0 };
  window.__nebula = diagnostics;

  function notify() {
    window.webkit?.messageHandlers?.nebula?.postMessage({
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
    if (!gl) throw new Error("Nebula requires WebGL 2, which is unavailable on this Mac.");
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

      float hash3(vec3 p) {
        p = fract(p * 0.1031);
        p += dot(p, p.zyx + 31.32);
        return fract((p.x + p.y) * p.z);
      }
      float noise3(vec3 x) {
        vec3 i = floor(x), f = fract(x);
        f = f * f * (3.0 - 2.0 * f);
        return mix(
          mix(mix(hash3(i), hash3(i + vec3(1, 0, 0)), f.x), mix(hash3(i + vec3(0, 1, 0)), hash3(i + vec3(1, 1, 0)), f.x), f.y),
          mix(mix(hash3(i + vec3(0, 0, 1)), hash3(i + vec3(1, 0, 1)), f.x), mix(hash3(i + vec3(0, 1, 1)), hash3(i + vec3(1, 1, 1)), f.x), f.y),
          f.z);
      }
      const mat3 ROT = mat3(0.00, 0.80, 0.60, -0.80, 0.36, -0.48, -0.60, -0.48, 0.64);
      float fbm3(vec3 p, int octaves) {
        float n = 0.0, a = 0.5, total = 0.0;
        for (int i = 0; i < 5; i++) {
          if (i >= octaves) break;
          n += a * noise3(p);
          total += a;
          p = ROT * p * 2.03;
          a *= 0.5;
        }
        return n / total;
      }

      const float CELL = 7.0;
      vec3 starIn(vec3 cell, out vec3 color, out float power) {
        float h = hash3(cell + 7.1);
        power = step(0.45, h) * (0.6 + 1.6 * hash3(cell + 3.3));
        float k = hash3(cell + 9.9);
        color = k < 0.4 ? vec3(0.65, 0.8, 1.0) : k < 0.75 ? vec3(1.0, 0.85, 0.65) : vec3(1.0, 0.6, 0.45);
        return (cell + 0.3 + 0.4 * vec3(hash3(cell), hash3(cell + 1.7), hash3(cell + 4.2))) * CELL;
      }

      vec2 path(float z) { return vec2(1.6 * sin(z * 0.07), 1.0 * sin(z * 0.05 + 1.0)); }

      vec3 palette(float k) {
        vec3 a = vec3(0.08, 0.45, 1.0);
        vec3 b = vec3(1.0, 0.16, 0.62);
        vec3 c = vec3(1.0, 0.52, 0.16);
        return k < 0.5 ? mix(a, b, smoothstep(0.1, 0.5, k)) : mix(b, c, smoothstep(0.5, 0.9, k));
      }

      void main() {
        vec2 p = (gl_FragCoord.xy - resolution * 0.5) / resolution.y;
        float t = time;
        float z = t * 0.17;
        vec3 ro = vec3(path(z), z);
        float roll = 0.15 * sin(t * 0.006);
        vec3 fw = normalize(vec3(path(z + 4.0) - path(z), 4.0));
        vec3 rt = normalize(cross(vec3(sin(roll), cos(roll), 0.0), fw));
        vec3 up = cross(fw, rt);
        vec3 rd = normalize(p.x * rt + p.y * up + 1.25 * fw);

        // Distant stars at infinity.
        vec3 c = vec3(0.004, 0.005, 0.012);
        vec2 sp = rd.xy / (abs(rd.z) + 0.6) * 260.0;
        vec2 sid = floor(sp), sf = fract(sp) - 0.5;
        float sh = hash(sid);
        if (sh > 0.93) {
          sf -= (vec2(hash(sid + 1.3), hash(sid + 4.1)) - 0.5) * 0.6;
          c += vec3(0.75, 0.82, 1.0) * exp(-dot(sf, sf) * 40.0) * pow(hash(sid + 8.0), 3.0) * 1.6 * (0.75 + 0.25 * sin(t * 2.0 + sh * 60.0));
        }

        float dither = hash(gl_FragCoord.xy + fract(t) * 17.0);
        float T = 1.0;
        vec3 light = vec3(0);
        float dist = 0.3 + dither * 0.22;
        float prev = 0.0;
        for (int i = 0; i < 52; i++) {
          vec3 pos = ro + rd * dist;
          float step = 0.2 + dist * 0.035;
          vec3 cell = floor(pos / CELL);
          vec3 starColor;
          float power;
          vec3 star = starIn(cell, starColor, power);
          vec3 toStar = star - pos;
          float sd2 = dot(toStar, toStar);

          float base = fbm3(pos * 0.28, 5);
          float filament = 1.0 - abs(2.0 * fbm3(pos * 0.7 + 11.0, 4) - 1.0);
          float corridor = length(pos.xy - path(pos.z)) + (base - 0.5) * 2.6;
          float den = smoothstep(0.5, 0.82, base) * smoothstep(0.2, 2.6, corridor) * (0.18 + 1.5 * pow(filament, 4.0));
          float dust = smoothstep(0.5, 0.72, fbm3(pos * 0.42 + 37.0, 3)) * smoothstep(0.35, 0.6, base) * smoothstep(0.8, 3.2, corridor);
          float illum = power * 2.2 * exp(-sd2 * 0.75);
          vec3 col = palette(fbm3(pos * 0.12 + 5.0, 2) * 1.25 - 0.1);
          col = mix(col, col * 0.4 + starColor * 0.75, clamp(illum * 0.3, 0.0, 0.55));
          vec3 emit = col * den * (0.2 + illum * 1.1) * (1.0 + 0.35 * breath);
          light += T * emit * step * 0.55;
          T *= exp(-(den * 0.34 + dust * 1.8) * step);

          // Embedded stars: add each one's glow once, where the ray passes it.
          float along = dot(star - ro, rd);
          if (power > 0.0 && along > prev && along <= dist + step && along > 0.5) {
            vec3 off = (star - ro) - rd * along;
            vec2 a = vec2(dot(off, rt), dot(off, up)) / along;
            float r2 = dot(a, a);
            float core = 2.5e-6 / (r2 + 2.5e-6);
            float spikes = exp(-abs(a.x) * 2200.0) * exp(-abs(a.y) * 55.0) + exp(-abs(a.y) * 2200.0) * exp(-abs(a.x) * 55.0);
            float halo = exp(-sqrt(r2) * 45.0) * 0.25;
            light += T * starColor * power * (core * 6.0 + spikes * 0.9 + halo) * (1.0 + 0.4 * breath) * min(1.0, 6.0 / along);
          }
          prev = dist + step;
          dist += step;
          if (T < 0.02 || dist > 22.0) break;
        }
        c = c * T + light;
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
      const scale = Math.min(1, Math.sqrt(520000 / (innerWidth * innerHeight)));
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
      gl.uniform1f(composite.uniform("exposure"), 1.05 + 0.1 * breathLevel());
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
      fail(new Error("The graphics context was lost. Select another theme and return to Nebula."));
    });
    draw(0);
    diagnostics.status = "ready";
    notify();
  } catch (error) {
    fail(error);
  }
})();
