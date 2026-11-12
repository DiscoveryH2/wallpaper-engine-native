import Foundation

/// A single primary Web presentation publishes its own media spectrum. Other
/// displays consume this value; switching projects invalidates the publisher.
@MainActor
final class WebMusicSpectrum {
    static let shared = WebMusicSpectrum()
    private var owner: UUID?
    private var values = [Float](repeating: 0, count: 128)
    private var updatedAt = -Double.infinity
    private(set) var status = "当前没有可分析的网页音乐。"
    var snapshot: [Float] { ProcessInfo.processInfo.systemUptime - updatedAt <= 0.5 ? values : [Float](repeating: 0, count: 128) }
    var isActive: Bool { owner != nil }
    func activate(_ id: UUID) {
        guard owner != id else { return }
        owner = id; clear(id)
    }
    func clear(_ id: UUID) {
        guard owner == id else { return }
        values = [Float](repeating: 0, count: 128); updatedAt = -.infinity
        status = "网页音乐频谱：当前没有活动媒体。"
    }
    func deactivate(_ id: UUID) { guard owner == id else { return }; clear(id); owner = nil }
    func publish(_ report: [String: Any], owner id: UUID) {
        guard owner == id, let array = report["values"] as? [NSNumber], array.count == 128 else { return }
        let next = array.map(\.floatValue)
        guard next.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 8 }) else { return }
        values = next; updatedAt = ProcessInfo.processInfo.systemUptime
        let count = (report["sources"] as? NSNumber)?.intValue ?? 0
        let peak = (report["peak"] as? NSNumber)?.doubleValue ?? 0
        let rate = (report["sampleRate"] as? NSNumber)?.doubleValue ?? 0
        status = count > 0 ? String(format: "网页音乐频谱 · %d 个媒体 · 当前峰值 %.4f · %.0f Hz", count, peak, rate) : "网页音乐频谱：当前没有活动媒体。"
    }
}

enum WebMusicBridge {
    /// Analysis uses detached, inaudible media copies. It never calls
    /// createMediaElementSource on an author's element or changes its graph.
    /// WebKit keeps control of streaming codec support and file/CORS rules.
    static func script(readRoot: URL) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: readRoot.path, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
        let root = String(decoding: data, as: UTF8.self)
        return #"""
        (() => {
          const root = \#(root);
          const zero = () => new Array(128).fill(0);
          let listener = null, context = null, mixer = null, splitter = null, left = null, right = null, silent = null;
          let suspended = false, resuming = false, idleSuspending = false, calls = 0, nonzero = 0, peak = 0, drift = 0, stateKey = '';
          const copies = new Map(), errors = [], rejected = new Set();
          const leftDB = new Float32Array(2048), rightDB = new Float32Array(2048);
          const leftPCM = new Float32Array(4096), rightPCM = new Float32Array(4096);
          const note = (error) => {
            const value = String(error && error.message || error).slice(0, 256);
            if (!errors.includes(value)) { errors.push(value); if (errors.length > 6) errors.shift(); }
          };
          const safeURL = (value) => {
            try {
              if (typeof value !== 'string' || value.length > 8192) return null;
              const url = new URL(value, document.baseURI);
              if (url.protocol !== 'file:' || url.host || url.search) return null;
              const path = decodeURIComponent(url.pathname);
              if (path.includes('\0') || path.includes('\\') || path.split('/').includes('..')) return null;
              if (!path.startsWith(root + '/Project/') && !path.startsWith(root + '/Media/')) return null;
              url.hash = ''; return url.href;
            } catch (_) { return null; }
          };
          const dispose = (record) => {
            record.disposed = true;
            record.player.pause(); record.player.removeAttribute('src'); record.player.load();
            try { record.node.disconnect(); record.gain.disconnect(); } catch (_) {}
          };
          const clear = () => { copies.forEach(dispose); copies.clear(); stateKey = ''; peak = 0; drift = 0; };
          const suspendIdle = () => {
            if (context && context.state === 'running' && !idleSuspending) {
              idleSuspending = true;
              context.suspend().catch(note).finally(() => { idleSuspending = false; });
            }
          };
          const initialize = () => {
            if (context) return true;
            const Constructor = window.AudioContext || window.webkitAudioContext;
            if (!Constructor) { note('WebKit 未提供 AudioContext。'); return false; }
            try {
              context = new Constructor();
              mixer = context.createGain(); mixer.channelCount = 2; mixer.channelCountMode = 'explicit'; mixer.channelInterpretation = 'speakers';
              splitter = context.createChannelSplitter(2);
              left = context.createAnalyser(); right = context.createAnalyser();
              for (const analyser of [left, right]) { analyser.fftSize = 4096; analyser.smoothingTimeConstant = 0; }
              silent = context.createGain(); silent.gain.value = 0;
              mixer.connect(splitter); splitter.connect(left, 0); splitter.connect(right, 1);
              left.connect(silent); right.connect(silent); silent.connect(context.destination);
              return true;
            } catch (error) { note(error); if (context) context.close().catch(() => {}); context = null; return false; }
          };
          const makeCopy = (element, url) => {
            const player = new Audio();
            player.preload = 'auto'; player.volume = 1; player.muted = false;
            const node = context.createMediaElementSource(player), gain = context.createGain();
            gain.channelCount = 2; gain.channelCountMode = 'explicit'; gain.channelInterpretation = 'speakers';
            gain.gain.value = 0; node.connect(gain); gain.connect(mixer);
            const record = {player, node, gain, url, disposed:false, playing:false, lastSeek:-Infinity, seekFinished:-Infinity, seeks:0};
            player.addEventListener('seeked', () => { record.seekFinished = performance.now(); });
            player.addEventListener('error', () => {
              if (record.disposed) return;
              note('网页音乐分析副本解码失败：' + (player.error && player.error.code || 'unknown'));
              if (rejected.size < 64) rejected.add(url);
            });
            player.src = url; player.load(); copies.set(element, record); return record;
          };
          const reduce = (db) => {
            const size = 4096, sampleRate = context.sampleRate, high = Math.min(20000, sampleRate / 2);
            const result = new Array(64);
            for (let band = 0; band < 64; ++band) {
              const lowerHz = 20 * Math.pow(high / 20, band / 64), upperHz = 20 * Math.pow(high / 20, (band + 1) / 64);
              const lower = Math.max(1, Math.min(db.length - 1, Math.floor(lowerHz * size / sampleRate)));
              const upper = Math.max(lower + 1, Math.min(db.length, Math.ceil(upperHz * size / sampleRate)));
              let energy = 0;
              for (let bin = lower; bin < upper; ++bin) if (Number.isFinite(db[bin])) energy += Math.pow(10, db[bin] / 10);
              result[band] = Math.min(8, Math.sqrt(energy) * 4);
            }
            return result;
          };
          const sampleOwnMusic = () => {
            const active = [];
            for (const element of Array.from(document.querySelectorAll('audio,video')).slice(0, 64)) {
              if (element.paused || element.ended || element.muted || element.volume <= 0 || element.readyState < 2) continue;
              if (!Number.isFinite(element.currentTime) || element.currentTime < 0 || !Number.isFinite(element.playbackRate) || element.playbackRate <= 0 || element.playbackRate > 16) continue;
              const url = safeURL(element.currentSrc);
              if (!url) { note('仅分析当前壁纸运行目录内的本机媒体；网络、blob 和流媒体仍由原页面播放。'); continue; }
              if (rejected.has(url)) continue;
              if (active.length >= 4) { note('网页音乐分析最多同时处理 4 个 HTML 媒体。'); break; }
              active.push({element, url});
            }
            const live = new Set(active.map((item) => item.element));
            for (const [element, record] of copies) if (!live.has(element) || active.find((item) => item.element === element).url !== record.url) { dispose(record); copies.delete(element); }
            if (!active.length) { stateKey = ''; peak = 0; drift = 0; suspendIdle(); return zero(); }
            if (!initialize()) return zero();
            if (context.state === 'suspended' && !resuming) {
              resuming = true; context.resume().catch(note).finally(() => { resuming = false; });
            }
            let ready = 0; drift = 0;
            const keys = [];
            for (const {element, url} of active) {
              try {
                const record = copies.get(element) || makeCopy(element, url), player = record.player;
                if (player.loop !== element.loop) player.loop = element.loop;
                if (player.playbackRate !== element.playbackRate) player.playbackRate = element.playbackRate;
                if ('preservesPitch' in player && player.preservesPitch !== element.preservesPitch) player.preservesPitch = element.preservesPitch;
                let delta = element.currentTime - player.currentTime;
                // A loop boundary is adjacent to time zero. Treating it as a
                // whole-clip drift would seek on every pass through the loop.
                if (element.loop && Number.isFinite(element.duration) && element.duration > 0 && Math.abs(delta) <= element.duration) {
                  if (delta > element.duration / 2) delta -= element.duration;
                  else if (delta < -element.duration / 2) delta += element.duration;
                }
                const offset = Math.abs(delta);
                const now = performance.now();
                drift = Math.max(drift, offset);
                if (player.readyState >= 2 && !player.seeking && !element.seeking && !record.playing && offset > 0.5
                    && now - record.lastSeek >= 1500 && now - record.seekFinished >= 750) {
                  record.lastSeek = now; record.seeks += 1; player.currentTime = element.currentTime;
                }
                if (player.paused && !record.playing) {
                  record.playing = true;
                  player.play().then(() => { if (record.disposed || suspended) player.pause(); }).catch((error) => { if (!record.disposed) note(error); }).finally(() => { record.playing = false; });
                }
                const synchronized = player.readyState >= 2 && !player.paused && !player.seeking && !element.seeking && offset <= 0.5;
                record.gain.gain.value = synchronized ? element.volume : 0;
                if (synchronized) ready += 1;
                keys.push(url + ':' + element.volume + ':' + element.playbackRate);
              } catch (error) { note(error); }
            }
            const key = keys.join('|'), changed = stateKey !== key; stateKey = key;
            if (!ready || changed || context.state !== 'running') { peak = 0; return zero(); }
            left.getFloatFrequencyData(leftDB); right.getFloatFrequencyData(rightDB);
            left.getFloatTimeDomainData(leftPCM); right.getFloatTimeDomainData(rightPCM);
            peak = 0;
            for (let index = 0; index < 4096; ++index) peak = Math.max(peak, Math.abs(leftPCM[index]), Math.abs(rightPCM[index]));
            return reduce(leftDB).concat(reduce(rightDB));
          };
          window.wallpaperRegisterAudioListener = (callback) => {
            if (typeof callback !== 'function') throw new TypeError('Audio listener must be a function');
            listener = callback;
          };
          window.__weNativePauseOwnAudio = async (paused) => {
            suspended = Boolean(paused);
            if (suspended) { clear(); if (context && context.state !== 'closed') await context.suspend().catch(note); }
            return {copies:copies.size, context:context ? context.state : 'none'};
          };
          window.__weNativeAudio = (input, mode) => {
            let values = zero();
            if (mode === 'wallpaper' && !suspended && listener) values = sampleOwnMusic();
            else {
              if (copies.size) clear();
              suspendIdle();
              if (mode !== 'paused' && Array.isArray(input) && input.length === 128) values = input.map((v) => Number.isFinite(v) ? Math.max(0, Math.min(8, v)) : 0);
            }
            if (listener && !suspended) {
              try { listener(values.slice()); calls += 1; if (values.some((v) => v > 0.0001)) nonzero += 1; }
              catch (error) { note('作者音频回调：' + (error && error.message || error)); }
            }
            const summary = 'Web 音乐频谱：' + mode + '，' + copies.size + ' 个静音分析副本，' + (context ? context.state + ' / ' + context.sampleRate + ' Hz' : '未创建音频图')
              + '；PCM peak=' + peak.toFixed(4) + '；最大时差=' + drift.toFixed(3) + 's；作者回调=' + calls + '，非零=' + nonzero
              + Array.from(copies).map(([element, record]) => '\n媒体时间=' + element.currentTime.toFixed(3) + 's，分析时间=' + record.player.currentTime.toFixed(3) + 's，ready=' + record.player.readyState + '，seeking=' + record.player.seeking + '，paused=' + record.player.paused + '，校正=' + record.seeks).join('')
              + (errors.length ? '\nWeb 音乐提示：' + errors.join(' | ') : '');
            return {values, summary, sources:copies.size, peak, sampleRate:context ? context.sampleRate : 0};
          };
          window.addEventListener('pagehide', () => {
            clear(); const previous = context; context = null;
            if (previous && previous.state !== 'closed') previous.close().catch(() => {});
          });
        })();
        """#
    }
}
