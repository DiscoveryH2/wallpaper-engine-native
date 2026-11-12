import Foundation

struct SceneSoundState {
    // Keep malformed authored values intact until the shared sound player can
    // diagnose and mute them. Numeric fallback-to-one would hide bad input.
    let volume: Any?
    let visible: Bool
    var minimum: Any? = nil
    var maximum: Any? = nil
}

/// Playback belongs to the presentation, not to GPU commands. Property updates
/// retain this object, its AVAudioPlayers and its single spectrum ownership.
@MainActor
final class NativeMetalSound {
    private(set) var signatures: [String]
    private(set) var layers: [SceneSoundLayer]
    private let owner = UUID()
    private var outputEnabled = false
    private var hostActive = false

    init(sources: [SceneSoundSource], states: [Int: SceneSoundState]) throws {
        signatures = sources.map(\.signature)
        layers = try sources.map { source in
            try SceneSoundLayer(source: source, initialVolume: states[source.index]?.volume,
                                initialMinimum: states[source.index]?.minimum, initialMaximum: states[source.index]?.maximum)
        }
    }
    var scriptStates: [String: [String: Any]] {
        Dictionary(uniqueKeysWithValues: layers.map { ($0.objectID, $0.scriptState) })
    }
    func preserveForInsertion(from previous: NativeMetalSound) {
        let old = Dictionary(uniqueKeysWithValues: zip(previous.layers, previous.signatures).map { ($0.0.objectID, ($0.0, $0.1)) })
        for index in layers.indices {
            if let match = old[layers[index].objectID], signatures[index] == match.1 { layers[index] = match.0 }
        }
    }
    /// Keep the presentation's output/spectrum owner, replacing only membership.
    func adoptPrepared(_ candidate: NativeMetalSound) { layers = candidate.layers; signatures = candidate.signatures }
    func retire(_ ids: Set<String>) {
        for layer in layers where ids.contains(layer.objectID) { layer.suspend() }
        signatures = zip(layers, signatures).filter { !ids.contains($0.0.objectID) }.map(\.1)
        layers.removeAll { ids.contains($0.objectID) }
        if outputEnabled && !NativeAudioService.shared.active {
            SceneMusicSpectrum.shared.update(owner: owner, inputs: layers.compactMap { $0.musicInput })
        }
    }
    var requiresUpdates: Bool { outputEnabled && hostActive && layers.contains { $0.needsUpdates } }
    var diagnostics: [String] {
        layers.flatMap { [$0.runtimeDiagnostic] + $0.diagnostics } +
        SceneMusicSpectrum.shared.diagnostics.map { "壁纸音乐频谱：" + $0 }
    }
    func setOutputEnabled(_ enabled: Bool) {
        guard outputEnabled != enabled else { return }
        outputEnabled = enabled
        if enabled { SceneMusicSpectrum.shared.activate(owner: owner) }
        else { suspend(); SceneMusicSpectrum.shared.deactivate(owner: owner) }
    }
    func suspend() {
        hostActive = false
        layers.forEach { $0.suspend() }
        SceneMusicSpectrum.shared.clear(owner: owner)
    }
    func refresh(states: [Int: SceneSoundState], scripts: SceneScriptBridge?, active: Bool) {
        // Init stop/pause must be applied before allowing autoplay on frame one.
        for command in scripts?.takeSoundCommands() ?? [] {
            if let sound = layers.first(where: { $0.objectID == command["id"] }), let action = command["action"] {
                sound.command(action)
            }
        }
        hostActive = active
        for sound in layers {
            let state = states[sound.objectIndex] ?? SceneSoundState(volume: 0, visible: false)
            sound.update(volume: state.volume, visible: state.visible, active: outputEnabled && active,
                         minimum: state.minimum, maximum: state.maximum)
        }
        if NativeAudioService.shared.active { SceneMusicSpectrum.shared.clear(owner: owner) }
        else if outputEnabled { SceneMusicSpectrum.shared.update(owner: owner, inputs: layers.compactMap { $0.musicInput }) }
    }
    deinit {
        let retiredOwner = owner
        Task { @MainActor in SceneMusicSpectrum.shared.deactivate(owner: retiredOwner) }
    }
}
