import DowlioMedia
import Foundation
import WebKit

enum PageWatcher {
    static let handlerName = "dowlioMedia"
    static let groupsPerFrame = 1000
    static let framesRead = 8
    static let passiveScript = "window.__dowlioPassive = true;"

    static let runScan = "window.__dowlioScanPage ? JSON.stringify(window.__dowlioScanPage()) : ''"

    static let scanScript: String? = {
        guard let url = Bundle.main.resourceURL?.appending(path: "Dowlio Connect/lib/scan.js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let plain = source.replacingOccurrences(of: "export function scanPage", with: "function scanPage")
        return """
            (() => {
              if (window.__dowlioScanPage) return;
              \(plain)
              window.__dowlioScanPage = () => { try { return scanPage(); } catch (e) { return {}; } };
              const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
              if (handler) handler.postMessage({ scanReady: true });
            })();
            """
    }()

    static let script = """
        (() => {
          if (window.__dowlioWatching) return;
          window.__dowlioWatching = true;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dowlioMedia;
          if (!handler) return;
          const sent = new Set();
          const media = /\\.(m3u8|mpd|mp4|m4v|mov|webm|m4a|mp3|aac)(\\?|#|$)/i;
          const send = (value, type, element) => {
            let url;
            try { url = new URL(String(value), location.href).href; } catch (e) { return; }
            if (!/^https?:/i.test(url)) return;
            const key = url + '|' + (type || '');
            if (sent.has(key)) return;
            sent.add(key);
            const message = { url, type: type || '', frame: location.href, agent: navigator.userAgent };
            if (element) message.element = true;
            handler.postMessage(message);
          };
          const check = (value) => { if (typeof value === 'string' && media.test(value.split('#')[0])) send(value); };
          const isMediaType = (type) => /mpegurl|dash\\+xml|^video\\/|^audio\\//i.test(type || '');
          const recent = [];
          const isPageAsset = (type) => /text\\/html|image\\/|font|css|javascript/i.test(type || '');
          const remember = (url, type) => {
            if (!url || isPageAsset(type)) return;
            recent.push({ url, type: type || '' });
            if (recent.length > 4) recent.shift();
          };
          const playlistType = (text) => {
            const start = (text || '').slice(0, 200).trimStart();
            if (start.startsWith('#EXTM3U')) return 'application/vnd.apple.mpegurl';
            if (/^(<\\?xml[^>]*>\\s*)?<MPD[\\s>]/.test(start)) return 'application/dash+xml';
            return null;
          };
          const reportRequestsBeforeFeeding = () => recent.splice(0).forEach((entry) => send(entry.url, entry.type, true));
          [window.MediaSource, window.ManagedMediaSource].forEach((Source) => {
            if (!Source || !Source.prototype || !Source.prototype.addSourceBuffer) return;
            const original = Source.prototype.addSourceBuffer;
            Source.prototype.addSourceBuffer = function () {
              reportRequestsBeforeFeeding();
              return original.apply(this, arguments);
            };
          });
          const open = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function (method, url) {
            check(String(url));
            this.addEventListener('load', () => {
              const type = this.getResponseHeader('content-type');
              if (isMediaType(type)) return send(this.responseURL, type);
              const text = this.responseType === '' || this.responseType === 'text' ? this.responseText : '';
              const listed = playlistType(text);
              if (listed) return send(this.responseURL, listed);
              remember(this.responseURL, type);
            });
            return open.apply(this, arguments);
          };
          const originalFetch = window.fetch;
          if (originalFetch) {
            window.fetch = function (input) {
              const url = typeof input === 'string' ? input : (input && input.url) || String(input);
              check(url);
              return originalFetch.apply(this, arguments).then((response) => {
                const type = response.headers && response.headers.get('content-type');
                const address = response.url || url;
                if (isMediaType(type)) {
                  send(address, type);
                } else if (response.headers && Number(response.headers.get('content-length')) > 0 && Number(response.headers.get('content-length')) < 2000000 && !isPageAsset(type)) {
                  response.clone().text().then((text) => {
                    const listed = playlistType(text);
                    if (listed) send(address, listed); else remember(address, type);
                  }).catch(() => {});
                }
                return response;
              });
            };
          }
          try {
            new PerformanceObserver((list) => list.getEntries().forEach((entry) => check(entry.name)))
              .observe({ type: 'resource', buffered: true });
          } catch (e) {}
          const originalPlay = HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play = function () {
            if (!window.__dowlioPassive) this.muted = true;
            return originalPlay.apply(this, arguments);
          };
          const play = () => {
            document.querySelectorAll('video, audio').forEach((element) => {
              if (!window.__dowlioPassive) {
                element.muted = true;
                element.volume = 0;
              }
              const source = element.currentSrc || element.src;
              if (source && !source.startsWith('blob:')) send(source, '', true);
              element.querySelectorAll('source[src]').forEach((child) => send(child.src, child.type, true));
            });
            try {
              if (typeof window.jwplayer === 'function') {
                const playlist = window.jwplayer().getPlaylist() || [];
                playlist.forEach((item) => {
                  check(item.file);
                  (item.sources || []).forEach((source) => check(source.file));
                });
              }
            } catch (e) {}
            const first = document.querySelector('video');
            if (!window.__dowlioPassive && first && first.paused) {
              const started = first.play();
              if (started && started.catch) started.catch(() => {});
            }
          };
          const pressPlay = () => {
            if (window.__dowlioPassive || window === window.top || innerWidth < 400 || innerHeight < 220) return;
            if (sent.size > 0) return;
            const target = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
            if (target) target.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
          };
          document.addEventListener('DOMContentLoaded', play);
          setInterval(play, 500);
          [1500, 2500, 3500].forEach((delay) => setTimeout(pressPlay, delay));
        })();
        """

    static func agent(in message: [String: Any]) -> String? {
        (message["agent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func request(from message: [String: Any], on page: URL) -> WatchedRequest? {
        guard let text = message["url"] as? String,
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let type = (message["type"] as? String).flatMap { $0.isEmpty ? nil : $0.split(separator: ";").first.map(String.init) }
        let isManifest = ["m3u8", "mpd"].contains(url.pathExtension.lowercased())
            || type.map { $0.contains("mpegurl") || $0.contains("dash+xml") } ?? false
        guard isManifest || message["element"] != nil || MediaFile.kind(of: url, contentType: type) != nil else { return nil }
        let frame = (message["frame"] as? String).flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        return WatchedRequest(url: url, kind: isManifest ? .manifest : .file, contentType: type, referrer: frame ?? page)
    }

    static func userScripts() -> [WKUserScript] {
        var scripts = [WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)]
        if let scanScript { scripts.append(WKUserScript(source: scanScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)) }
        return scripts
    }

    @MainActor
    static func render(_ webView: WKWebView, frames: [WKFrameInfo]) async -> (html: String?, scan: PageScan) {
        var scan = PageScan([:])
        let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String
        let ordered = frames.filter(\.isMainFrame) + frames.filter { !$0.isMainFrame }
        for (index, frame) in ordered.enumerated() {
            let reply = try? await webView.evaluateJavaScript(runScan, in: frame, contentWorld: .page)
            guard let text = reply as? String, let found = PageScan(json: text) else { continue }
            scan.join(found, offsettingGroupsBy: index * groupsPerFrame)
        }
        return (html, scan)
    }
}
