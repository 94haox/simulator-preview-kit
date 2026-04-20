import Foundation

enum EmbeddedWebAssets {
    static let hlsJS = loadTextResource(named: "hls.min", extension: "js")

    static let stylesCSS = """
    :root {
      color-scheme: light;
      --bg: #fff;
      --panel: #fff;
      --line: #d7deea;
      --text: #172033;
      --muted: #5f6b7d;
      --accent: #2563eb;
    }

    * { box-sizing: border-box; }
    html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text); font: 14px/1.4 -apple-system, BlinkMacSystemFont, sans-serif; }
    body { min-height: 100vh; display: flex; flex-direction: column; }
    header { padding: 16px 20px 10px; border-bottom: 1px solid var(--line); }
    h1 { margin: 0; font-size: 16px; }
    p { margin: 6px 0 0; color: var(--muted); }
    main { flex: 1; display: grid; place-items: center; padding: 20px; }
    .device-shell {
      width: min(100%, 460px);
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 8px;
      overflow: hidden;
      box-shadow: 0 20px 50px rgba(15,23,42,0.08);
      outline: none;
    }
    .toolbar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 10px 12px;
      border-bottom: 1px solid var(--line);
      background: #f8fafc;
      color: var(--muted);
      font-size: 12px;
    }
    .media-stage {
      position: relative;
      width: 100%;
      background: #fff;
      aspect-ratio: 390 / 844;
      overflow: hidden;
    }
    #canvas,
    #frame {
      position: absolute;
      inset: 0;
      width: 100%;
      height: 100%;
      object-fit: contain;
      display: block;
      background: #fff;
      user-select: none;
      -webkit-user-drag: none;
    }
    #canvas[hidden],
    #frame[hidden] {
      display: none;
    }
    .hint {
      padding: 10px 12px 16px;
      color: var(--muted);
      font-size: 12px;
      border-top: 1px solid var(--line);
      background: #f8fafc;
    }
    code {
      color: var(--accent);
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
    }
    """

    static let appJS = """
    const bootstrap = window.__PREVIEW_BOOTSTRAP__ || {};
    const canvasEl = document.getElementById('canvas');
    const frameEl = document.getElementById('frame');
    const statusEl = document.getElementById('status');
    const modeEl = document.getElementById('mode');
    const shellEl = document.getElementById('surface');
    const deviceEl = document.getElementById('device');
    const intervalMs = bootstrap.frameIntervalMs || 150;
    const ctx = canvasEl.getContext('2d');

    let activeFrameURL = null;
    let isPointerDown = false;
    let imageFallbackStarted = false;
    let ws = null;
    let wsConnected = false;
    let reconnectTimer = null;
    let pendingBitmap = null;
    let fpsCount = 0;
    let fpsStart = 0;

    deviceEl.textContent = bootstrap.deviceName || 'Preview Device';

    function setStatus(text) {
      statusEl.textContent = text;
    }

    function setMode(text) {
      modeEl.textContent = `Mode: ${text}`;
    }

    function hitTarget() {
      return canvasEl.hidden ? frameEl : canvasEl;
    }

    function normalizePoint(event) {
      const rect = hitTarget().getBoundingClientRect();
      if (!rect.width || !rect.height) {
        return { x: 0, y: 0 };
      }
      const x = Math.max(0, Math.min(1, (event.clientX - rect.left) / rect.width));
      const y = Math.max(0, Math.min(1, (event.clientY - rect.top) / rect.height));
      return { x, y };
    }

    function sendEvent(payload) {
      const json = JSON.stringify(payload);
      if (ws && wsConnected) {
        ws.send(json);
        return;
      }
      fetch('/input', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: json,
      }).catch(() => {});
    }

    function renderBitmap(bitmap) {
      if (canvasEl.width !== bitmap.width || canvasEl.height !== bitmap.height) {
        canvasEl.width = bitmap.width;
        canvasEl.height = bitmap.height;
      }
      ctx.drawImage(bitmap, 0, 0);
      bitmap.close();
      canvasEl.hidden = false;
      frameEl.hidden = true;

      const now = performance.now();
      if (!fpsStart) {
        fpsStart = now;
        fpsCount = 0;
        return;
      }
      fpsCount++;
      const elapsed = now - fpsStart;
      if (elapsed >= 1000) {
        const fps = (fpsCount * 1000) / elapsed;
        setStatus(`${fps.toFixed(0)} fps`);
        fpsCount = 0;
        fpsStart = now;
      }
    }

    function updateFrameFallback(blob) {
      const nextURL = URL.createObjectURL(blob);
      frameEl.hidden = false;
      canvasEl.hidden = true;
      frameEl.src = nextURL;
      if (activeFrameURL) {
        URL.revokeObjectURL(activeFrameURL);
      }
      activeFrameURL = nextURL;
    }

    function refreshFrame() {
      fetch(`/frame?ts=${Date.now()}`, { cache: 'no-store' })
        .then((response) => {
          if (response.status === 204) {
            setStatus('Waiting for frame...');
            return null;
          }
          if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
          }
          return response.blob();
        })
        .then((blob) => {
          if (!blob) return;
          updateFrameFallback(blob);
          setStatus('Live');
        })
        .catch(() => {
          setStatus('Frame request failed');
        })
        .finally(() => {
          if (imageFallbackStarted && !wsConnected) {
            window.setTimeout(refreshFrame, intervalMs);
          }
        });
    }

    function startImageFallback(reason) {
      if (imageFallbackStarted) return;
      imageFallbackStarted = true;
      setMode('screenshot');
      setStatus(reason || 'Falling back to image polling...');
      refreshFrame();
    }

    function stopImageFallback() {
      imageFallbackStarted = false;
    }

    function connectWebSocket() {
      if (reconnectTimer) {
        clearTimeout(reconnectTimer);
        reconnectTimer = null;
      }

      const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
      const wsURL = `${protocol}//${location.host}/ws`;

      setStatus('Connecting...');
      setMode('websocket');

      try {
        ws = new WebSocket(wsURL);
      } catch (_) {
        startImageFallback('WebSocket not supported, falling back to image polling...');
        return;
      }

      ws.binaryType = 'arraybuffer';

      ws.onopen = () => {
        wsConnected = true;
        stopImageFallback();
        setMode('WebSocket');
        setStatus('Live');
      };

      ws.onmessage = (event) => {
        if (!(event.data instanceof ArrayBuffer)) return;
        const blob = new Blob([event.data], { type: 'image/jpeg' });
        createImageBitmap(blob).then((bitmap) => {
          if (pendingBitmap) {
            pendingBitmap.close();
          }
          pendingBitmap = null;
          renderBitmap(bitmap);
        }).catch(() => {});

        if (!wsConnected) {
          wsConnected = true;
          stopImageFallback();
          setMode('WebSocket');
        }
      };

      ws.onclose = () => {
        wsConnected = false;
        ws = null;
        setStatus('Disconnected');
        startImageFallback('WebSocket closed, falling back to image polling...');
        reconnectTimer = window.setTimeout(connectWebSocket, 2000);
      };

      ws.onerror = () => {
        // onclose will fire after onerror
      };
    }

    shellEl.addEventListener('pointerdown', (event) => {
      shellEl.focus();
      isPointerDown = true;
      const point = normalizePoint(event);
      sendEvent({ kind: 'touchDown', x: point.x, y: point.y });
      event.preventDefault();
    });

    shellEl.addEventListener('pointermove', (event) => {
      if (!isPointerDown) return;
      const point = normalizePoint(event);
      sendEvent({ kind: 'touchMove', x: point.x, y: point.y });
      event.preventDefault();
    });

    shellEl.addEventListener('pointerup', (event) => {
      if (!isPointerDown) return;
      isPointerDown = false;
      const point = normalizePoint(event);
      sendEvent({ kind: 'touchUp', x: point.x, y: point.y });
      event.preventDefault();
    });

    shellEl.addEventListener('pointercancel', () => {
      isPointerDown = false;
    });

    shellEl.addEventListener('wheel', (event) => {
      sendEvent({ kind: 'scroll', deltaX: event.deltaX, deltaY: event.deltaY });
      event.preventDefault();
    }, { passive: false });

    shellEl.addEventListener('keydown', (event) => {
      sendEvent({
        kind: 'keyDown',
        key: event.key,
        code: event.code,
        modifiers: {
          shift: event.shiftKey,
          control: event.ctrlKey,
          option: event.altKey,
          command: event.metaKey,
        },
      });

      if ([
        'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight',
        'Backspace', 'Tab', 'Enter', ' '
      ].includes(event.key)) {
        event.preventDefault();
      }
    });

    connectWebSocket();
    """

    static func indexHTML(deviceName: String, frameIntervalMs: Int, initialMode: String) -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>Simulator Preview</title>
          <link rel="stylesheet" href="/styles.css" />
        </head>
        <body>
          <header>
            <h1>Simulator Preview</h1>
            <p>Local preview bridge. Click the device area to focus keyboard input.</p>
          </header>
          <main>
            <section id="surface" class="device-shell" tabindex="0">
              <div class="toolbar">
                <span id="device">\(deviceName)</span>
                <span id="mode">Mode: \(initialMode)</span>
                <span id="status">Connecting...</span>
              </div>
              <div class="media-stage">
                <canvas id="canvas" hidden></canvas>
                <img id="frame" alt="Simulator preview frame" hidden />
              </div>
              <div class="hint">
                WebSocket preview. Pointer = touch, wheel = scroll, keyboard forwarded.
              </div>
            </section>
          </main>
          <script>
            window.__PREVIEW_BOOTSTRAP__ = { deviceName: \(jsonString(deviceName)), frameIntervalMs: \(frameIntervalMs), initialMode: \(jsonString(initialMode)) };
          </script>
          <script src="/app.js"></script>
        </body>
        </html>
        """
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return String(data: data ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
    }

    private static func loadTextResource(named name: String, extension fileExtension: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension) else {
            return ""
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
