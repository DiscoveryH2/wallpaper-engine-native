import Foundation

/// Injected into the main WebKit document at document start. The system still
/// owns rendering and media; this bounded compatibility bridge stops the page
/// timers it observes and retains their remaining delays across host pauses.
enum WebPauseBridge {
    static let script = #"""
    (() => {
      let paused = false;
      const originalRAF = window.requestAnimationFrame.bind(window);
      const originalCancelRAF = window.cancelAnimationFrame.bind(window);
      const originalSetTimeout = window.setTimeout.bind(window);
      const originalClearTimeout = window.clearTimeout.bind(window);
      const monotonicNow = performance.now.bind(performance);
      const globalEval = (0, eval);
      let nextFrameHandle = 1;
      const pending = new Map();
      const nativeHandles = new Map();
      const playingMedia = new Set();
      let nextTimerHandle = 1;
      const timers = new Map();

      // A zero native rate holds CSS/WAAPI progress without calling play/pause
      // on behalf of the host. Those methods would permanently override CSS
      // animation-play-state. Author calls still reach the original methods.
      const animationPause = (() => {
        const noop = () => {};
        if (typeof window.Animation !== 'function' || typeof document.getAnimations !== 'function')
          return {holdAll: noop, resume: noop};
        const proto = Animation.prototype;
        const rate = Object.getOwnPropertyDescriptor(proto, 'playbackRate');
        if (!rate || !rate.get || !rate.set || !rate.configurable)
          return {holdAll: noop, resume: noop};
        const held = new Map();
        const requestedRates = new WeakMap();
        const animations = document.getAnimations.bind(document);
        const nativeRate = a => rate.get.call(a);
        const setNativeRate = (a, value) => rate.set.call(a, value);
        const supported = a => a.timeline === document.timeline ||
          (typeof window.DocumentTimeline === 'function' && a.timeline instanceof DocumentTimeline);
        const hold = a => {
          if (!paused || held.has(a) || !supported(a) || a.playState !== 'running') return;
          const speed = requestedRates.has(a) ? requestedRates.get(a) : nativeRate(a);
          if (speed === 0) {
            // An author-requested zero may still be pending in WebKit.
            // Commit it now; it must also stay zero when the host resumes.
            if (requestedRates.has(a)) { setNativeRate(a, 0); requestedRates.delete(a); }
            return;
          }
          setNativeRate(a, 0);
          requestedRates.delete(a);
          held.set(a, speed);
        };
        const holdAll = () => {
          if (!paused) return;
          // One incompatible author object must not prevent other animations
          // or the timer/media bridge from receiving their pause transition.
          for (const a of animations()) { try { hold(a); } catch (_) {} }
        };
        const release = a => {
          if (!held.has(a)) return;
          const speed = held.get(a);
          held.delete(a);
          setNativeRate(a, speed);
        };
        Object.defineProperty(proto, 'playbackRate', {
          ...rate,
          get: function() { return held.has(this) ? held.get(this) : rate.get.call(this); },
          set: function(value) {
            // Let WebKit perform WebIDL conversion/validation exactly once.
            // A throwing assignment retains the previous held speed.
            rate.set.call(this, value);
            held.delete(this);
            requestedRates.delete(this);
            hold(this);
          }
        });
        for (const name of ['play', 'pause', 'cancel', 'finish', 'reverse', 'updatePlaybackRate']) {
          const descriptor = Object.getOwnPropertyDescriptor(proto, name);
          if (!descriptor || typeof descriptor.value !== 'function' || !descriptor.writable) continue;
          const original = descriptor.value;
          Object.defineProperty(proto, name, {...descriptor, value: function(...args) {
            const actual = nativeRate(this); // Keep native receiver validation.
            if (!supported(this)) return Reflect.apply(original, this, args);
            // Restore the author's speed for native operations such as finish
            // and reverse; otherwise a host-imposed zero rate changes them.
            const previous = held.has(this) ? held.get(this) :
              (requestedRates.has(this) ? requestedRates.get(this) : actual);
            release(this);
            try {
              let requested;
              if (name === 'updatePlaybackRate') {
                requested = +args[0];
                args = [requested];
              }
              const result = Reflect.apply(original, this, args);
              // Pending speed changes cannot wait for a rendered frame while
              // held. Commit the requested speed before saving the new hold.
              if (name === 'updatePlaybackRate') requestedRates.set(this, requested);
              else if (name === 'reverse' && previous !== 0) requestedRates.set(this, -previous);
              if (paused && requestedRates.has(this)) {
                setNativeRate(this, requestedRates.get(this));
                requestedRates.delete(this);
              }
              return result;
            } finally { hold(this); }
          }});
        }
        const animate = window.Element && Object.getOwnPropertyDescriptor(Element.prototype, 'animate');
        if (animate && typeof animate.value === 'function' && animate.writable) {
          const original = animate.value;
          Object.defineProperty(Element.prototype, 'animate', {...animate, value: function(...args) {
            const a = Reflect.apply(original, this, args);
            hold(a);
            return a;
          }});
        }
        if (typeof window.MutationObserver === 'function') {
          const observer = new MutationObserver(holdAll);
          observer.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
        }
        document.addEventListener('animationstart', holdAll, true);
        document.addEventListener('transitionrun', holdAll, true);
        return {holdAll, resume: () => {
          for (const a of Array.from(held.keys())) { try { release(a); } catch (_) { held.delete(a); } }
        }};
      })();

      const allocateTimerHandle = () => {
        const first = nextTimerHandle;
        do {
          const handle = nextTimerHandle;
          nextTimerHandle = handle >= 2147483647 ? 1 : handle + 1;
          if (!timers.has(handle)) return handle;
        } while (nextTimerHandle !== first);
        throw new RangeError('Timer handle space exhausted');
      };
      const delayValue = (value) => Math.max(0, (+value) | 0);
      const armTimer = (record, remaining) => {
        if (paused || record.native !== null || timers.get(record.id) !== record) return;
        const wait = Math.max(0, remaining);
        record.remaining = wait;
        record.due = monotonicNow() + wait;
        record.native = originalSetTimeout(() => fireTimer(record.id), wait);
      };
      const fireTimer = (id) => {
        const record = timers.get(id);
        if (!record) return;
        record.native = null;
        if (paused) { record.remaining = 0; return; }
        if (!record.repeats) timers.delete(id);
        record.invoking = true;
        try {
          if (typeof record.handler === 'function') record.handler.apply(window, record.args);
          else globalEval(record.handler);
        } finally {
          record.invoking = false;
          if (record.repeats && timers.get(id) === record && !paused) armTimer(record, record.delay);
        }
      };
      const addTimer = (repeats, handler, delay, args) => {
        const callback = typeof handler === 'function' ? handler : '' + handler;
        const duration = delayValue(delay);
        const id = allocateTimerHandle();
        const record = {id, repeats, handler: callback, args, delay: duration,
          remaining: duration, due: 0, native: null, invoking: false};
        timers.set(id, record);
        armTimer(record, duration);
        return id;
      };
      const clearTimer = (value) => {
        const id = (+value) | 0;
        const record = timers.get(id);
        if (!record) return;
        timers.delete(id);
        if (record.native !== null) originalClearTimeout(record.native);
        record.native = null;
      };
      window.setTimeout = (handler, delay = 0, ...args) => addTimer(false, handler, delay, args);
      window.setInterval = (handler, delay = 0, ...args) => addTimer(true, handler, delay, args);
      // HTML timers share one handle map; either clear method cancels either kind.
      window.clearTimeout = clearTimer;
      window.clearInterval = clearTimer;

      const scheduleFrame = (handle) => {
        if (paused || nativeHandles.has(handle) || !pending.has(handle)) return;
        nativeHandles.set(handle, originalRAF((timestamp) => {
          nativeHandles.delete(handle);
          if (paused) return;
          const callback = pending.get(handle);
          pending.delete(handle);
          if (callback) callback(timestamp);
        }));
      };
      window.requestAnimationFrame = (callback) => {
        const handle = nextFrameHandle++;
        pending.set(handle, callback); scheduleFrame(handle); return handle;
      };
      window.cancelAnimationFrame = (handle) => {
        pending.delete(handle);
        const nativeHandle = nativeHandles.get(handle);
        if (nativeHandle !== undefined) originalCancelRAF(nativeHandle);
        nativeHandles.delete(handle);
      };
      window.__weNativeSetPaused = (value) => {
        const next = Boolean(value);
        if (next === paused) return;
        paused = next;
        if (paused) {
          const now = monotonicNow();
          timers.forEach((record) => {
            if (record.native !== null) {
              originalClearTimeout(record.native);
              record.native = null;
              record.remaining = Math.max(0, record.due - now);
            } else if (record.invoking) record.remaining = record.delay;
          });
          nativeHandles.forEach((handle) => originalCancelRAF(handle));
          nativeHandles.clear();
          document.querySelectorAll('video, audio').forEach((element) => {
            if (!element.paused) { playingMedia.add(element); element.pause(); }
          });
          animationPause.holdAll();
        } else {
          animationPause.resume();
          playingMedia.forEach((element) => element.play().catch(() => {}));
          playingMedia.clear();
          timers.forEach((record) => armTimer(record, record.remaining));
          pending.forEach((_, handle) => scheduleFrame(handle));
        }
        const listener = window.wallpaperPropertyListener;
        try {
          if (listener && typeof listener.setPaused === 'function') listener.setPaused(paused);
        } finally { animationPause.holdAll(); }
      };
    })();
    """#
}
