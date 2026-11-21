# LiveContainer Debug Studio & JIT-Less Network Engine

LiveContainer includes an in-process **JIT-Less Developer Instrumentation Agent** inside `TweakLoader` paired with a modular **iOS 27 Liquid Glass Debug Studio** (`LiveContainerSwiftUI/Views/DebugMode/`). Everything operates without JIT, debugserver attachment, or Man-in-the-Middle proxy configuration.

---

## Architecture Overview

```text
TweakLoader/
├── LCDebugAgent.m                # HTTP + SSE server, Mac LAN Console, UI/Log/Crash/OSLog hooks
└── NetworkEngine/
    ├── LCDebugNetworkTypes.h/.m      # Runtime class safety, swizzle helpers, compression, cURL, models
    ├── LCDebugNetworkBodyCache.h/.m  # O(1) doubly-linked-list LRU payload cache with memory-warning purge
    ├── LCDebugURLSessionHooks.h/.m   # NSURLSession, task cluster, WebSocket frame, & NSURLConnection hooks
    ├── LCDebugWebViewHook.h/.m       # Isolated WKWebView fetch / XHR / sendBeacon / console JS bridge
    └── LCDebugNetworkEngine.h/.m     # Coordinator, transaction store, HAR 1.2 exporter, & request replay

LiveContainerSwiftUI/Views/DebugMode/
├── LCDebugModels.swift               # Sendable/Equatable models + nonisolated formatters/parsers
├── LCDebugStudioManager.swift        # @MainActor @Observable per-domain stores & SSE client
├── LCDebugTelemetryBar.swift         # Isolated 1Hz CPU/RAM/FPS/LAN strip
├── LCDebugStudioView.swift           # Framed viewport coordinator + 3-detent drawer / landscape split
├── Network/
│   ├── LCDebugNetworkPanelView.swift   # Search, filters, stats strip, swipe actions, HAR export
│   ├── LCDebugNetworkDetailSheet.swift # Overview waterfall, Request/Response, Pretty JSON, Image, Hex
│   └── LCDebugNetworkSheets.swift      # Network capture settings, Replay editor, & file share sheet
└── Panels/
    ├── LCDebugConsoleAndEventsPanels.swift   # Live Console & UI/Runtime Events panels
    ├── LCDebugHierarchyPanel.swift           # Interactive collapsible View Hierarchy Tree
    └── LCDebugRuntimeAndSandboxPanels.swift  # Dylibs, ObjC Class Inspector, Sandbox, & Tap-Inspect sheet
```

---

## Non-Invasive Plaintext HTTPS Observation (Zero TLS Weakening)

Rather than weakening TLS trust checks or disabling certificate pinning, `LCDebugNetworkEngine` observes traffic **inside the app process at the Foundation and WebKit API boundaries**:

- **Outgoing requests** (`NSURLRequest`, headers, `HTTPBody`, `uploadData`, `uploadFile` size, copyable `HTTPBodyStream`, `WKWebView` `fetch`/`XHR`/`sendBeacon`) are captured in plaintext **before** TLS encryption occurs in `CFNetwork`/`Network.framework`.
- **Incoming responses** (`NSHTTPURLResponse` headers, status codes, MIME types, completion buffers, streaming delegate chunks, downloaded file payloads) are captured in plaintext **after** the system performs standard TLS handshake, certificate chain validation, ATS enforcement, and custom SSL pinning verification.
- **Connection & TLS phase timings** (DNS, TCP, TLS, request send, TTFB wait, receive, ALPN protocol, connection reuse, remote endpoint) are read passively via `URLSession:task:didFinishCollectingMetrics:`.

This allows inspecting HTTPS payloads even for apps that strictly pin their server certificates, without compromising transport security.

---

## Network Capture Coverage & Endpoints

### Captured Paths
- `NSURLSession` completion-handler, delegate-based, non-completion, and Swift Concurrency `async`/`await` tasks across base and concrete cluster classes (`__NSURLSessionLocal`, `__NSURLBackgroundSession`, `__NSCFLocalSessionTask`, `__NSCFBackgroundSessionTask`).
- Session-level delegates (`+[NSURLSession sessionWithConfiguration:delegate:delegateQueue:]`), one-shot safe delegate class discovery (`LCDebugIsSafeObjCClass` + `class_copyMethodList`), and iOS 15+ per-task delegates (`-[NSURLSessionTask setDelegate:]`).
- HTTP redirects (`willPerformHTTPRedirection`), downloads (`didWriteData`, `didFinishDownloadingToURL:`), uploads (`fromData`, `fromFile`, `streamedRequest`), and `resumeData` downloads.
- `NSURLSessionWebSocketTask` outgoing/incoming frames (`sendMessage:`, `receiveMessageWithCompletionHandler:`, `cancelWithCloseCode:reason:`).
- Legacy `NSURLConnection` (`sendSynchronousRequest:`, `sendAsynchronousRequest:`) deduplicated against underlying `NSURLSession` forwarding.
- `WKWebView` JavaScript bridge (`fetch`, `XMLHttpRequest`, `navigator.sendBeacon`, `console.*`, `error`, `unhandledrejection`) capturing absolute URLs, headers, MIME types, and payloads.

### Bounded Memory & Streaming Design
- SSE frames (`event: network`) push compact transaction metadata + `<= 1 KiB` body previews with live in-flight state transitions (`pending` → `receiving` → `finished` / `failed`, throttled at `<= 4 Hz` during streaming).
- Full request and response bodies (`<= 2 MiB` per entry, compressed responses automatically inflated via `Compression.framework`) live in an `O(1)` doubly-linked-list `LCDebugNetworkBodyCache` (configurable `4–50 MiB` budget, auto-purged on memory warning).
- Full payloads load on demand via `GET /api/network/body?id=<id>&part=request|response&redact=0|1`.
- Additional HTTP endpoints on `LCDebugServer`:
  - `GET /api/network` — snapshot of retained transactions
  - `GET /api/network/har?redact=0|1` — HAR 1.2 export with optional sensitive header redaction
  - `GET /api/network/settings` — capture pause, cache limits, retention, and excluded host rules
  - `POST /api/network/replay` — in-process HTTP/HTTPS request replay
