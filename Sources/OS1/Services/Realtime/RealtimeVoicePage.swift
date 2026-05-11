import Foundation

/// The HTML+JS page served from the voice server's `GET /` endpoint.
/// Lives in its own file (was 520 lines stuffed inside
/// `RealtimeVoiceSessionServer.swift`).
///
/// JS-side flow:
///   1. fetch `/signed-url` to get an ElevenLabs Convai WSS URL
///   2. open WebSocket
///   3. capture mic via getUserMedia → downsample → PCM16 → base64 frames
///   4. play received `audio` events through Web Audio API
///   5. handle `client_tool_call` events by hitting `/tool` (orgo_*),
///      `/codex-*` (legacy company_*), or `/wuphf/*` (current AI office).
enum RealtimeVoicePage {
    static let html: String = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>OS1 Realtime Voice</title>
      <style>
        :root {
          color-scheme: dark;
          --bg: #c65a43;
          --panel: rgba(255,255,255,.10);
          --panel-strong: rgba(255,255,255,.18);
          --border: rgba(255,255,255,.28);
          --text: rgba(255,255,255,.95);
          --muted: rgba(255,255,255,.64);
          --ok: #b7e3ca;
          --warn: #ffd89a;
        }
    
        * { box-sizing: border-box; }
        body {
          margin: 0;
          min-height: 100vh;
          background: var(--bg);
          color: var(--text);
          font: 14px/1.45 -apple-system, BlinkMacSystemFont, "DM Sans", "Helvetica Neue", sans-serif;
        }
    
        main {
          display: grid;
          grid-template-rows: auto 1fr auto;
          gap: 14px;
          min-height: 100vh;
          padding: 18px;
        }
    
        header {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 12px;
        }
    
        h1 {
          margin: 0;
          font-size: 17px;
          font-weight: 400;
          letter-spacing: 0;
        }
    
        .status {
          color: var(--muted);
          font-size: 12px;
          white-space: nowrap;
        }
    
        .orb {
          display: grid;
          place-items: center;
          width: min(52vw, 220px);
          aspect-ratio: 1;
          justify-self: center;
          align-self: center;
          border-radius: 999px;
          background: radial-gradient(circle at 50% 42%, rgba(255,255,255,.24), rgba(255,255,255,.10) 42%, rgba(255,255,255,.04) 70%);
          border: 1px solid var(--border);
          box-shadow: inset 0 0 60px rgba(255,255,255,.10);
          transition: transform .2s ease, background .2s ease;
        }
    
        .orb.connected {
          background: radial-gradient(circle at 50% 42%, rgba(183,227,202,.38), rgba(255,255,255,.12) 44%, rgba(255,255,255,.04) 72%);
        }
    
        .orb.listening {
          transform: scale(1.03);
        }
    
        .orb span {
          color: var(--text);
          font-size: 12px;
          text-transform: uppercase;
          letter-spacing: 1.6px;
        }
    
        .controls {
          display: grid;
          gap: 10px;
        }
    
        button {
          appearance: none;
          width: 100%;
          border: 1px solid var(--border);
          border-radius: 8px;
          background: var(--panel);
          color: var(--text);
          padding: 11px 12px;
          font: inherit;
          cursor: pointer;
        }
    
        button:hover { background: var(--panel-strong); }
        button:disabled { opacity: .45; cursor: default; }
    
        .row {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 10px;
        }
    
        pre {
          min-height: 86px;
          max-height: 132px;
          overflow: auto;
          margin: 0;
          padding: 10px;
          border: 1px solid var(--border);
          border-radius: 8px;
          background: rgba(40,30,24,.16);
          color: var(--muted);
          font: 11px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace;
          white-space: pre-wrap;
        }
      </style>
    </head>
    <body>
      <main>
        <header>
          <h1>Realtime Voice</h1>
          <div class="status" id="status">idle</div>
        </header>
    
        <section class="orb" id="orb" aria-live="polite">
          <span id="orb-label">offline</span>
        </section>
    
        <section class="controls">
          <div class="row">
            <button id="start">Start</button>
            <button id="stop" disabled>Stop</button>
          </div>
          <pre id="log"></pre>
        </section>
      </main>
    
      <script>
        const TARGET_RATE = 16000;
        const statusEl = document.getElementById("status");
        const orb = document.getElementById("orb");
        const orbLabel = document.getElementById("orb-label");
        const logEl = document.getElementById("log");
        const startButton = document.getElementById("start");
        const stopButton = document.getElementById("stop");
    
        let ws;
        let audioContext;
        let micStream;
        let micSource;
        let micProcessor;
        let micSink;
        let nextPlayTime = 0;
        let conversationId = null;
        let lastAgentAudioAt = 0;
        const AGENT_TAIL_MS = 250;
    
        function postStatus(message) {
          statusEl.textContent = message;
          if (window.webkit?.messageHandlers?.voiceStatus) {
            window.webkit.messageHandlers.voiceStatus.postMessage({ status: message });
          }
        }
    
        function log(line) {
          const stamp = new Date().toLocaleTimeString();
          logEl.textContent = `[${stamp}] ${line}\\n` + logEl.textContent;
          if (window.webkit?.messageHandlers?.voiceStatus) {
            window.webkit.messageHandlers.voiceStatus.postMessage({ status: "log: " + line });
          }
        }
    
        function pcm16FromFloat32(float32) {
          const out = new Int16Array(float32.length);
          for (let i = 0; i < float32.length; i++) {
            const s = Math.max(-1, Math.min(1, float32[i]));
            out[i] = s < 0 ? s * 0x8000 : s * 0x7FFF;
          }
          return out;
        }
    
        function bytesToBase64(bytes) {
          let binary = "";
          const chunk = 0x8000;
          for (let i = 0; i < bytes.length; i += chunk) {
            binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
          }
          return btoa(binary);
        }
    
        function base64ToBytes(b64) {
          const binary = atob(b64);
          const bytes = new Uint8Array(binary.length);
          for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
          return bytes;
        }
    
        function downsample(float32, fromRate, toRate) {
          if (fromRate === toRate) return float32;
          const ratio = fromRate / toRate;
          const outLength = Math.floor(float32.length / ratio);
          const out = new Float32Array(outLength);
          for (let i = 0; i < outLength; i++) {
            const start = Math.floor(i * ratio);
            const end = Math.min(float32.length, Math.floor((i + 1) * ratio));
            let sum = 0;
            let count = 0;
            for (let j = start; j < end; j++) { sum += float32[j]; count++; }
            out[i] = count > 0 ? sum / count : 0;
          }
          return out;
        }
    
        async function getSignedURL() {
          const r = await fetch("/signed-url");
          if (!r.ok) throw new Error((await r.text()) || ("signed-url " + r.status));
          const j = await r.json();
          if (!j.signed_url) throw new Error("signed-url response missing signed_url");
          return j.signed_url;
        }
    
        async function fetchOrgoTools() {
          try {
            const r = await fetch("/tools");
            const j = await r.json();
            if (j.orgo?.status) log(j.orgo.status);
            return Array.isArray(j.tools) ? j.tools : [];
          } catch (e) {
            log("tools fetch failed: " + e.message);
            return [];
          }
        }
    
        function clientToolFromOpenAI(t) {
          return {
            type: "client",
            name: t.name,
            description: t.description,
            parameters: t.parameters,
          };
        }
    
        function playPCM(b64) {
          if (!audioContext) return;
          const bytes = base64ToBytes(b64);
          if (bytes.byteLength === 0) return;
          const sampleCount = Math.floor(bytes.byteLength / 2);
          const int16 = new Int16Array(bytes.buffer, bytes.byteOffset, sampleCount);
          const float32 = new Float32Array(sampleCount);
          for (let i = 0; i < sampleCount; i++) float32[i] = int16[i] / 0x8000;
    
          const buffer = audioContext.createBuffer(1, sampleCount, TARGET_RATE);
          buffer.copyToChannel(float32, 0);
    
          const playAt = Math.max(audioContext.currentTime, nextPlayTime);
          const source = audioContext.createBufferSource();
          source.buffer = buffer;
          source.connect(audioContext.destination);
          source.start(playAt);
          nextPlayTime = playAt + buffer.duration;
        }
    
        function clearPlayback() {
          if (audioContext) nextPlayTime = audioContext.currentTime;
        }
    
        async function handleToolCall(call) {
          if (!call) return;
          const name = call.tool_name;
          const id = call.tool_call_id;
          let args = call.parameters;
          if (typeof args === "string") {
            try { args = JSON.parse(args); } catch (_) { args = {}; }
          }
          args = args || {};
          let result;
          let isError = false;
          try {
            if (typeof name === "string" && name.startsWith("wuphf_")) {
              const map = {
                wuphf_post:        { url: "/wuphf/post",        body: { channel: args.channel || "general", content: args.content || "", author: "samantha" } },
                wuphf_read:        { url: "/wuphf/read",        body: { channel: args.channel || "general" } },
                wuphf_list_members:{ url: "/wuphf/members",     body: {} },
                wuphf_wiki_search: { url: "/wuphf/wiki-search", body: { query: args.query || "" } },
              };
              const route = map[name];
              if (!route) {
                result = { error: "unknown wuphf tool: " + name };
                isError = true;
              } else {
                const r = await fetch(route.url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(route.body) });
                const data = await r.json();
                isError = !r.ok || data.ok === false;
                result = data;
                log(name + " -> " + (isError ? "error" : "ok"));
              }
            } else if (typeof name === "string" && name.startsWith("company_")) {
              const map = {
                company_create: { url: "/codex-spawn", body: { task: args.mission, title: args.name, cadence_minutes: args.cadence_minutes } },
                company_list: { url: "/codex-list", method: "GET" },
                company_journal: { url: "/codex-tail", body: { id: args.id } },
                company_intervene: { url: "/codex-intervene", body: { id: args.id, instruction: args.instruction } },
                company_pause: { url: "/codex-pause", body: { id: args.id } },
                company_resume: { url: "/codex-resume", body: { id: args.id } },
              };
              const route = map[name];
              if (!route) {
                result = { error: "unknown company tool: " + name };
                isError = true;
              } else {
                const opts = route.method === "GET"
                  ? {}
                  : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(route.body) };
                const r = await fetch(route.url, opts);
                const data = await r.json();
                isError = !r.ok || data.ok === false;
                result = data;
                log(name + " -> " + (isError ? "error" : "ok"));
              }
            } else if (typeof name === "string" && name.startsWith("orgo_")) {
              const r = await fetch("/tool", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ name, arguments: args }),
              });
              const data = await r.json();
              isError = data.isError === true || !r.ok;
              result = data;
              // Strip large base64 payloads before sending back to the LLM.
              // The full screenshot bytes (often 600KB-1MB) blow Claude's
              // context limit and crash the conversation. The user sees the
              // live screen in the Tiles tab anyway.
              if (name === "orgo_screenshot" && !isError) {
                result = { text: "Screenshot taken — visible in the OS1 Tiles tab. (Image bytes stripped to keep the conversation context small.)" };
              }
              if (typeof result === "object") {
                const serialized = JSON.stringify(result);
                if (serialized.length > 2000) {
                  result = { text: serialized.slice(0, 1500) + "...[truncated]" };
                }
              }
              if (isError) {
                let detail = "";
                try {
                  if (Array.isArray(data?.content)) {
                    detail = data.content.map(c => c?.text || JSON.stringify(c)).join(" | ").slice(0, 400);
                  } else {
                    detail = JSON.stringify(data).slice(0, 400);
                  }
                } catch (_) { detail = String(data).slice(0, 400); }
                log(name + " -> error: " + detail);
              } else {
                log(name + " -> ok");
              }
            } else {
              result = { error: "unknown tool: " + name };
              isError = true;
            }
          } catch (e) {
            result = { error: e.message };
            isError = true;
          }
          if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({
              type: "client_tool_result",
              tool_call_id: id,
              result: typeof result === "string" ? result : JSON.stringify(result),
              is_error: isError,
            }));
          }
        }
    
        async function handleEvent(msg) {
          switch (msg.type) {
            case "conversation_initiation_metadata":
              conversationId = msg.conversation_initiation_metadata_event?.conversation_id;
              orb.classList.add("connected");
              orbLabel.textContent = "online";
              log("connected" + (conversationId ? " " + conversationId : ""));
              break;
            case "audio": {
              const b64 = msg.audio_event?.audio_base_64;
              if (b64) {
                lastAgentAudioAt = performance.now();
                playPCM(b64);
              }
              break;
            }
            case "user_transcript":
              log("user: " + (msg.user_transcription_event?.user_transcript || ""));
              break;
            case "agent_response":
              log("agent: " + (msg.agent_response_event?.agent_response || ""));
              break;
            case "interruption":
              clearPlayback();
              break;
            case "client_tool_call":
              await handleToolCall(msg.client_tool_call);
              break;
            case "ping":
              if (ws && ws.readyState === WebSocket.OPEN) {
                ws.send(JSON.stringify({ type: "pong", event_id: msg.ping_event?.event_id }));
              }
              break;
            default:
              break;
          }
        }
    
        async function startVoice() {
          if (ws) return;
          startButton.disabled = true;
          postStatus("requesting microphone");
          orbLabel.textContent = "starting";
    
          try {
            const orgoTools = await fetchOrgoTools();
            const url = await getSignedURL();
    
            audioContext = new (window.AudioContext || window.webkitAudioContext)();
            nextPlayTime = audioContext.currentTime;
            micStream = await navigator.mediaDevices.getUserMedia({
              audio: {
                channelCount: 1,
                echoCancellation: true,
                noiseSuppression: true,
              },
            });
    
            ws = new WebSocket(url);
            ws.onopen = () => {
              const init = { type: "conversation_initiation_client_data" };
              if (orgoTools.length > 0) {
                init.conversation_config_override = {
                  agent: {
                    prompt: {
                      tools: orgoTools.map(clientToolFromOpenAI),
                    },
                  },
                };
              }
              ws.send(JSON.stringify(init));
              log("ws open, init sent (" + orgoTools.length + " tools)");
              orb.classList.add("listening");
              orbLabel.textContent = "listening";
              postStatus("listening");
              stopButton.disabled = false;
            };
            ws.onmessage = (e) => {
              try {
                handleEvent(JSON.parse(e.data));
              } catch (err) {
                log("event parse failed: " + err.message);
              }
            };
            ws.onerror = () => log("ws error");
            ws.onclose = (e) => {
              log("ws closed " + (e.code || "") + (e.reason ? (": " + e.reason) : ""));
              stopVoice("disconnected");
            };
    
            const sourceRate = audioContext.sampleRate;
            micSource = audioContext.createMediaStreamSource(micStream);
            micProcessor = audioContext.createScriptProcessor(4096, 1, 1);
            micProcessor.onaudioprocess = (ev) => {
              if (!ws || ws.readyState !== WebSocket.OPEN) return;
              // Suppress mic capture while agent audio is playing or just played,
              // to avoid speakers→mic feedback loops on devices without good AEC.
              if (performance.now() - lastAgentAudioAt < AGENT_TAIL_MS) return;
              const float32 = ev.inputBuffer.getChannelData(0);
              const downsampled = downsample(float32, sourceRate, TARGET_RATE);
              const pcm16 = pcm16FromFloat32(downsampled);
              const b64 = bytesToBase64(new Uint8Array(pcm16.buffer, pcm16.byteOffset, pcm16.byteLength));
              ws.send(JSON.stringify({ user_audio_chunk: b64 }));
            };
            micSource.connect(micProcessor);
            micSink = audioContext.createGain();
            micSink.gain.value = 0;
            micProcessor.connect(micSink);
            micSink.connect(audioContext.destination);
          } catch (error) {
            log("start failed: " + error.message);
            stopVoice("error: " + error.message);
          }
        }
    
        function stopVoice(status) {
          status = status || "stopped";
          try { if (ws) ws.close(); } catch (_) {}
          ws = null;
          if (micProcessor) { try { micProcessor.disconnect(); } catch (_) {} micProcessor = null; }
          if (micSource) { try { micSource.disconnect(); } catch (_) {} micSource = null; }
          if (micSink) { try { micSink.disconnect(); } catch (_) {} micSink = null; }
          if (micStream) { micStream.getTracks().forEach((t) => t.stop()); micStream = null; }
          if (audioContext) { try { audioContext.close(); } catch (_) {} audioContext = null; }
          orb.classList.remove("connected", "listening");
          orbLabel.textContent = "offline";
          postStatus(status);
          startButton.disabled = false;
          stopButton.disabled = true;
        }
    
        startButton.addEventListener("click", startVoice);
        stopButton.addEventListener("click", () => stopVoice("stopped"));
    
        postStatus("idle");
        setTimeout(startVoice, 250);
      </script>
    </body>
    </html>
    """
}
