import Foundation

/// A transaction produces one candidate at a time. The host acknowledges it
/// only after preparation and display publication succeed. A stale completion
/// cannot advance a changed list or take ownership from a manual selection.
struct NativePlaylistPlayback: Equatable {
    enum Reason: String, Codable { case login, timer, calendar, videoEnd, intro, next, refresh }
    struct Request: Equatable {
        let id: UUID
        let entry: NativePlaylistEntry
        let reason: Reason
    }
    struct Position: Codable, Equatable {
        var current: UUID?
        var remaining: [UUID] = []
        var elapsed: Double = 0
    }
    private(set) var list: NativePlaylist
    private(set) var position: Position
    private(set) var pending: Request?
    private var lastTick: Double
    private var lastCalendarMinute: Int?
    private var startup = true
    private var introActive = false
    private var unavailableUntil: [UUID: Double] = [:]

    init(list: NativePlaylist, now: Double, position: Position = Position()) {
        self.list = list; self.list.normalize()
        let ids = Set(list.entries.map(\.id))
        self.position = position
        self.position.current = position.current.flatMap { ids.contains($0) ? $0 : nil }
        self.position.remaining = Array(position.remaining.filter { ids.contains($0) }.prefix(10_000))
        if !position.elapsed.isFinite || position.elapsed < 0 { self.position.elapsed = 0 }
        lastTick = now
    }
    var currentEntry: NativePlaylistEntry? { list.entries.first { $0.id == position.current } }

    /// Begin a newly selected temporary list immediately. Calendar lists use
    /// their current interval; timer intros retain their existing video-end
    /// behavior. The host still prepares and acknowledges this request before
    /// changing presentation ownership or retiring the previous wallpaper.
    mutating func initial(now: Double, date: Date, calendar: Calendar = .current,
                          choose: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Request? {
        guard pending == nil, !list.entries.isEmpty else { return nil }
        startup = false; lastTick = now
        if list.settings.mode == .daytime || list.settings.mode == .dayofweek,
           let index = list.scheduledIndex(at: date, calendar: calendar), list.entries.indices.contains(index),
           available(list.entries[index], now: now) {
            lastCalendarMinute = Int(date.timeIntervalSince1970 / 60)
            return request(list.entries[index], reason: .calendar)
        }
        if list.settings.mode == .timer, list.settings.beginFirst,
           let first = list.entries.first, available(first, now: now) {
            return request(first, reason: .intro)
        }
        return selectNext(.login, now: now, choose: choose)
    }

    mutating func replace(_ next: NativePlaylist, now: Double) {
        let current = currentEntry?.wallpaper.key
        list = next; list.normalize(); pending = nil; startup = false; introActive = false
        let ids = Set(list.entries.map(\.id))
        position.remaining.removeAll { !ids.contains($0) }
        if !ids.contains(position.current ?? UUID()) {
            position.current = list.entries.first { $0.wallpaper.key == current }?.id
        }
        position.elapsed = 0; lastTick = now; lastCalendarMinute = nil
        unavailableUntil = unavailableUntil.filter { ids.contains($0.key) }
    }

    mutating func manualSelection(key: String?, now: Double, starting: Bool = false) {
        pending = nil
        let previous = position.current
        position.current = list.entries.first { $0.wallpaper.key == key }?.id
        if !starting || previous != position.current { position.elapsed = 0 }
        lastTick = now; introActive = false
        if !starting { startup = false }
    }

    /// REA: 0x140076be0 caps an individual elapsed update to five seconds,
    /// suppresses accumulation while paused, and treats delays below .01 min
    /// as disabled. Calendar selection (0x140067a00) uses local hour/minute.
    mutating func tick(now: Double, date: Date, paused: Bool, video: Bool,
                       suspended: Bool = false, calendar: Calendar = .current,
                       choose: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Request? {
        let delta = now.isFinite && lastTick.isFinite ? min(5, max(0, now - lastTick)) : 0
        lastTick = now
        guard !suspended, pending == nil, list.entries.count >= 2 else { return nil }
        guard !paused || list.settings.updateOnPause else { return nil }
        let isStartup = startup; startup = false
        if isStartup {
            if list.settings.mode == .logon { return selectNext(.login, now: now, choose: choose) }
            if list.settings.mode == .timer, list.settings.beginFirst,
               let first = list.entries.first, available(first, now: now) {
                return request(first, reason: .intro)
            }
        }
        switch list.settings.mode {
        case .daytime, .dayofweek:
            let minute = Int(date.timeIntervalSince1970 / 60)
            guard minute != lastCalendarMinute else { return nil }
            lastCalendarMinute = minute
            guard let index = list.scheduledIndex(at: date, calendar: calendar),
                  list.entries.indices.contains(index) else { return nil }
            let entry = list.entries[index]
            guard entry.id != position.current, available(entry, now: now) else { return nil }
            return request(entry, reason: .calendar)
        case .timer:
            guard list.settings.delay >= 0.01 else { return nil }
            position.elapsed += delta
            guard !(video && (list.settings.videoSequence || introActive)),
                  position.elapsed >= list.settings.delay * 60 else { return nil }
            return selectNext(.timer, now: now, choose: choose)
        case .logon, .never: return nil
        }
    }

    /// Called only by the committed desktop video's end notification. Repeated
    /// end events from mirrored displays cannot create a second load.
    mutating func videoEnded(now: Double, paused: Bool, choose: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Request? {
        guard pending == nil, list.entries.count >= 2, list.settings.mode == .timer,
              !paused || list.settings.updateOnPause,
              list.settings.videoSequence || introActive else { return nil }
        return selectNext(.videoEnd, now: now, choose: choose)
    }
    mutating func next(now: Double, choose: (Int) -> Int = { Int.random(in: 0..<$0) }) -> Request? {
        guard pending == nil, list.entries.count >= 2 else { return nil }
        startup = false
        return selectNext(.next, now: now, choose: choose)
    }
    mutating func refreshCurrent(now: Double) -> Request? {
        guard pending == nil, let entry = currentEntry else { return nil }
        lastTick = now
        return request(entry, reason: .refresh)
    }
    @discardableResult
    mutating func complete(_ request: Request, succeeded: Bool, now: Double) -> Bool {
        guard pending?.id == request.id, list.entries.contains(where: { $0.id == request.entry.id }) else { return false }
        pending = nil; lastTick = now
        if succeeded {
            position.current = request.entry.id
            if request.reason != .refresh {
                position.elapsed = 0
                introActive = request.reason == .intro && list.settings.playIntro
            }
            unavailableUntil[request.entry.id] = nil
        } else {
            // Native file validation can skip absent entries; asynchronous Mac
            // preparation can also fail. Keep the old display and bound retries.
            unavailableUntil[request.entry.id] = now + 60
        }
        return true
    }
    mutating func cancelPending(now: Double) { pending = nil; lastTick = now }
    mutating func interruptedByUser(now: Double) { pending = nil; lastTick = now; startup = false }

    private func available(_ entry: NativePlaylistEntry, now: Double) -> Bool {
        (unavailableUntil[entry.id] ?? -.infinity) <= now
    }
    private mutating func request(_ entry: NativePlaylistEntry, reason: Reason) -> Request {
        let value = Request(id: UUID(), entry: entry, reason: reason); pending = value; return value
    }
    private mutating func selectNext(_ reason: Reason, now: Double, choose: (Int) -> Int) -> Request? {
        var eligible = list.entries
        if list.settings.mode == .timer, list.settings.beginFirst, list.settings.playIntro, eligible.count > 1 {
            eligible.removeFirst()
        }
        guard !eligible.isEmpty else { return nil }
        let chosen: NativePlaylistEntry?
        if list.settings.random {
            let ids = Set(eligible.map(\.id))
            position.remaining.removeAll { !ids.contains($0) }
            if position.remaining.isEmpty {
                position.remaining = eligible.map(\.id)
                if position.remaining.count > 1, let current = position.current {
                    position.remaining.removeAll { $0 == current }
                }
            }
            let candidates = eligible.filter { position.remaining.contains($0.id) && available($0, now: now) }
            guard !candidates.isEmpty else { return nil }
            chosen = candidates[min(candidates.count - 1, max(0, choose(candidates.count)))]
            position.remaining.removeAll { $0 == chosen?.id }
        } else {
            let current = eligible.firstIndex { $0.id == position.current }
            let start = current.map { ($0 + 1) % eligible.count } ?? 0
            chosen = (0..<eligible.count).lazy.map { eligible[(start + $0) % eligible.count] }.first { available($0, now: now) }
        }
        guard let chosen else { return nil }
        return request(chosen, reason: reason)
    }
}
