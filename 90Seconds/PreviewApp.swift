import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics
import IOKit.hidsystem
import OSLog
import SwiftUI

private let volumeLog = Logger(subsystem: "local.ninetyseconds.preview", category: "Volume")

@main
struct PreviewApp: App {
    @NSApplicationDelegateAdaptor(PreviewDelegate.self) private var delegate

    var body: some Scene {
        Window("90 seconds", id: "preview") {
            PreviewView(preview: delegate.preview)
        }
        .defaultSize(width: 500, height: 330)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About 90 seconds") {
                    let website = "https://triplestep.se/"
                    let credits = NSMutableAttributedString(string: "Designed by Tomas Nilsson\n")
                    credits.append(NSAttributedString(string: website, attributes: [.link: website]))
                    NSApp.orderFrontStandardAboutPanel(options: [.version: "", .credits: credits])
                }
            }
            DiagnosticsCommands()
        }

        Window("Diagnostics", id: "diagnostics") {
            DiagnosticsView(preview: delegate.preview)
        }
        .defaultSize(width: 540, height: 320)
    }
}

private struct DiagnosticsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Enable Debugging Window") { openWindow(id: "diagnostics") }
        }
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var preview: Preview

    private var logText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let header = "90 Seconds version \(version) (build \(build))"
        return preview.diagnostics.isEmpty ? header : "\(header)\n\n\(preview.diagnostics)"
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            ScrollView {
                Text(verbatim: logText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Copy Log", action: copyLog)
        }
        .padding()
        .onAppear { preview.setDiagnosticsOpen(true) }
        .onDisappear { preview.setDiagnosticsOpen(false) }
    }

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }
}

@MainActor
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let preview = Preview()

    func applicationDidFinishLaunching(_ notification: Notification) {
        preview.observeAudioOutput()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        preview.stop()
        preview.stopObservingAudioOutput()
    }
}

struct PreviewView: View {
    @ObservedObject var preview: Preview

    private var statusMessage: String? {
        if let status = preview.status { return status }
        if !preview.isRunning && !preview.hasActiveAudioOutput {
            return "Start playback and check your output volume."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GeometryReader { geometry in
                TimelineView(.animation(minimumInterval: 0.1, paused: !preview.isRunning)) { _ in
                    let clock = preview.elapsedClock
                    let clockLabel = preview.phase == .gap ? "Elapsed gap time" : "Elapsed time"
                    let fontSize = min(geometry.size.height * 0.8,
                                       geometry.size.width / CGFloat(clock.count) * 1.5)
                    ZStack {
                        if preview.isPlaying || preview.phase == .gap {
                            Image(systemName: preview.isPlaying ? "play.fill" : "pause.fill")
                                .font(.system(size: min(geometry.size.height, geometry.size.width) * 0.74))
                                .foregroundStyle(.secondary.opacity(0.16))
                                .accessibilityHidden(true)
                        }
                        Text(clock)
                            .font(.system(size: max(1, fontSize), weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .minimumScaleFactor(0.1)
                            .accessibilityLabel(clockLabel)
                            .accessibilityValue(clock)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: clock) { _, elapsed in
                        preview.recordClockTick(elapsed)
                    }
                }
            }
            .frame(minHeight: 120)
            .padding(8)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 10) {
                durationSlider("Play duration", seconds: $preview.playSeconds, minimum: 1)
                durationSlider("Gap duration", seconds: $preview.gapSeconds, minimum: 0)
            }
            .disabled(preview.isRunning)

            Divider()

            HStack(spacing: 10) {
                transportButton("Reset timer", icon: "arrow.counterclockwise", action: preview.reset)
                    .disabled(!preview.isPlaying)
                transportButton("Previous Track", icon: "backward.end.fill", action: preview.previousTrack)
                    .disabled(preview.isRunning && !preview.isPlaying)
                if preview.isRunning {
                    transportButton("Stop", icon: "stop.fill", action: preview.stop)
                } else {
                    transportButton("Start", icon: "play.fill", action: preview.start)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!preview.hasActiveAudioOutput)
                }
                transportButton("Next Track", icon: "forward.end.fill", action: preview.nextTrack)
                    .disabled(preview.isRunning && !preview.isPlaying)
            }
            .frame(maxWidth: .infinity)

            if let message = statusMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 340)
        .padding(20)
    }

    private func transportButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(title)
        .help(title)
    }

    private func durationSlider(_ label: String, seconds: Binding<Int>, minimum: Int) -> some View {
        let maximum = Preview.maximumDurationSeconds
        let position = Binding<Double>(
            get: { log1p(Double(seconds.wrappedValue - minimum)) },
            set: { seconds.wrappedValue = minimum + Int(expm1($0).rounded()) }
        )

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text("\(seconds.wrappedValue) s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Slider(value: position, in: 0...log1p(Double(maximum - minimum))) {
                Text(label)
            }
            .labelsHidden()
            .accessibilityValue("\(seconds.wrappedValue) seconds")
        }
    }
}

private enum MediaKey {
    case playPause
    case previousTrack
    case nextTrack

    static func requestAccessIfNeeded() throws {
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }
        guard CGPreflightPostEventAccess() else {
            throw MediaKeyError.accessDenied
        }
    }

    func post() throws {
        guard CGPreflightPostEventAccess() else {
            throw MediaKeyError.accessDenied
        }

        let code: Int32
        switch self {
        case .playPause: code = NX_KEYTYPE_PLAY
        case .previousTrack: code = NX_KEYTYPE_REWIND
        case .nextTrack: code = NX_KEYTYPE_FAST
        }
        guard let down = event(code: Int(code), state: Int(NX_KEYDOWN)),
              let up = event(code: Int(code), state: Int(NX_KEYUP)) else {
            throw MediaKeyError.eventCreationFailed
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func event(code: Int, state: Int) -> CGEvent? {
        NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS),
            data1: (code << 16) | (state << 8),
            data2: -1
        )?.cgEvent
    }
}

private enum MediaKeyError: LocalizedError {
    case accessDenied
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            let section: String
            if #available(macOS 27, *) {
                section = "Device Control and Data Access"
            } else {
                section = "Accessibility"
            }
            return "Allow this copy of 90 seconds in System Settings → Privacy & Security → \(section). Quit and reopen the app, then click Start."
        case .eventCreationFailed:
            return "Could not create the media key event."
        }
    }
}

@MainActor
final class Preview: ObservableObject {
    @Published private(set) var diagnostics = ""
    private var diagnosticsOpen = false

    enum Phase {
        case idle, playing, changingTrack, gap
    }

    static let maximumDurationSeconds = 3_600

    @Published var playSeconds: Int {
        didSet { defaults.set(playSeconds, forKey: "playSeconds") }
    }
    @Published var gapSeconds: Int {
        didSet { defaults.set(gapSeconds, forKey: "gapSeconds") }
    }
    @Published private(set) var status: String?
    @Published private(set) var hasActiveAudioOutput = false
    @Published private(set) var phase: Phase = .idle
    @Published private var phaseStart: ContinuousClock.Instant?

    private let defaults: UserDefaults
    private var task: Task<Void, Never>?
    private var volumeBeforeFade: OutputVolume?
    private var phaseDuration: Duration = .zero

    private let audioSystem = AudioObjectID(kAudioObjectSystemObject)
    private var audioProcessList = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var processOutput = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningOutput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var observedAudioProcesses: Set<AudioObjectID> = []
    private var observedOutputDevice = AudioObjectID(kAudioObjectUnknown)
    private var isObservingAudioOutput = false
    private lazy var audioOutputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated {
            self?.refreshAudioOutput()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedPlay = defaults.object(forKey: "playSeconds") as? Int ?? 90
        let savedGap = defaults.object(forKey: "gapSeconds") as? Int ?? 10
        playSeconds = min(max(1, savedPlay), Self.maximumDurationSeconds)
        gapSeconds = min(max(0, savedGap), Self.maximumDurationSeconds)
    }

    var isRunning: Bool { phase != .idle }
    var isPlaying: Bool { phase == .playing }

    var elapsedClock: String {
        let elapsed = phaseStart.map { min($0.duration(to: .now), phaseDuration) } ?? .zero
        let seconds = elapsed.components.seconds
        return "\(seconds / 60):\(String(format: "%02d", Int(seconds % 60)))"
    }

    func observeAudioOutput() {
        guard !isObservingAudioOutput else { return }
        guard #available(macOS 14.2, *) else {
            status = "Audio output detection requires macOS 14.2 or later."
            return
        }
        guard AudioObjectAddPropertyListenerBlock(
            audioSystem, &audioProcessList, .main, audioOutputListener
        ) == noErr else {
            status = "Could not monitor audio output on this Mac."
            return
        }
        isObservingAudioOutput = true
        var defaultOutput = OutputVolume.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(audioSystem, &defaultOutput, .main, audioOutputListener)
        refreshAudioOutput()
    }

    func stopObservingAudioOutput() {
        guard isObservingAudioOutput else { return }
        isObservingAudioOutput = false
        AudioObjectRemovePropertyListenerBlock(audioSystem, &audioProcessList, .main, audioOutputListener)
        var defaultOutput = OutputVolume.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(audioSystem, &defaultOutput, .main, audioOutputListener)
        observeOutputDevice(AudioObjectID(kAudioObjectUnknown))
        for process in observedAudioProcesses {
            AudioObjectRemovePropertyListenerBlock(process, &processOutput, .main, audioOutputListener)
        }
        observedAudioProcesses.removeAll()
    }

    private func observeOutputDevice(_ device: AudioObjectID) {
        guard device != observedOutputDevice else { return }
        for var address in [OutputVolume.muteAddress, OutputVolume.address] {
            if observedOutputDevice != kAudioObjectUnknown {
                AudioObjectRemovePropertyListenerBlock(observedOutputDevice, &address, .main, audioOutputListener)
            }
            if device != kAudioObjectUnknown && AudioObjectHasProperty(device, &address) {
                AudioObjectAddPropertyListenerBlock(device, &address, .main, audioOutputListener)
            }
        }
        observedOutputDevice = device
    }

    private func refreshAudioOutput() {
        guard isObservingAudioOutput else { return }
        let outputDevice = OutputVolume.defaultDevice()
        observeOutputDevice(outputDevice)
        var size: UInt32 = 0
        let objectSize = MemoryLayout<AudioObjectID>.stride
        guard AudioObjectGetPropertyDataSize(audioSystem, &audioProcessList, 0, nil, &size) == noErr else {
            hasActiveAudioOutput = false
            return
        }

        var processes = [AudioObjectID](repeating: 0, count: Int(size) / objectSize)
        if !processes.isEmpty {
            let result = processes.withUnsafeMutableBufferPointer { buffer in
                AudioObjectGetPropertyData(audioSystem, &audioProcessList, 0, nil, &size, buffer.baseAddress!)
            }
            guard result == noErr else {
                hasActiveAudioOutput = false
                return
            }
        }

        let currentProcesses = Set(processes.prefix(Int(size) / objectSize))
        for process in observedAudioProcesses.subtracting(currentProcesses) {
            AudioObjectRemovePropertyListenerBlock(process, &processOutput, .main, audioOutputListener)
            observedAudioProcesses.remove(process)
        }
        for process in currentProcesses.subtracting(observedAudioProcesses) {
            if AudioObjectAddPropertyListenerBlock(process, &processOutput, .main, audioOutputListener) == noErr {
                observedAudioProcesses.insert(process)
            }
        }

        let isActive = outputDevice != kAudioObjectUnknown && !OutputVolume.isSilenced(outputDevice)
            && currentProcesses.contains { process in
                var running: UInt32 = 0
                var runningSize = UInt32(MemoryLayout<UInt32>.size)
                return AudioObjectGetPropertyData(process, &processOutput, 0, nil, &runningSize, &running) == noErr
                    && running != 0
            }
        if hasActiveAudioOutput != isActive {
            hasActiveAudioOutput = isActive
        }
    }

    func start() {
        guard task == nil else { return }
        refreshAudioOutput()
        guard hasActiveAudioOutput else { return }
        do {
            try MediaKey.requestAccessIfNeeded()
            guard restoreVolume() else { return }
            beginRun()
        } catch {
            status = error.localizedDescription
        }
    }

    func reset() {
        guard isPlaying else { return }
        if cancelRun() {
            beginRun()
        }
    }

    func previousTrack() {
        changeTrack(.previousTrack)
    }

    func nextTrack() {
        changeTrack(.nextTrack)
    }

    private func changeTrack(_ key: MediaKey) {
        guard !isRunning || isPlaying else { return }
        let restart = isPlaying
        do {
            try MediaKey.requestAccessIfNeeded()
            guard cancelRun() else { return }
            try key.post()
            if restart {
                beginRun()
            } else {
                status = nil
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func beginRun() {
        let play = Duration.seconds(playSeconds)
        let gap = Duration.seconds(gapSeconds)
        status = nil
        beginPlaying(for: play)
        task = Task {
            await run(play: play, gap: gap)
        }
    }

    func stop() {
        _ = cancelRun()
    }

    private func cancelRun() -> Bool {
        task?.cancel()
        clearRun()
        return restoreVolume()
    }

    private func clearRun() {
        phaseStart = nil
        task = nil
        phase = .idle
    }

    private func run(play: Duration, gap: Duration) async {
        defer {
            if !Task.isCancelled {
                clearRun()
            }
        }

        do {
            while true {
                guard let start = phaseStart else { return }
                try await playPhase(from: start, duration: play)

                // Pause the current track at zero volume and hold that level through the gap.
                if gap > .zero {
                    try MediaKey.playPause.post()
                    recordDiagnostic("Gap enabled. Sent Play/Pause to pause the current track.")
                    let gapStart = ContinuousClock.now
                    phaseDuration = gap
                    phaseStart = gapStart
                    phase = .gap
                    recordDiagnostic("Gap timer reset to 0:00. Waiting \(gap.components.seconds) seconds.")
                    try await Task.sleep(until: gapStart.advanced(by: gap), clock: .continuous)
                    try Task.checkCancellation()
                    recordDiagnostic("Gap complete.")
                } else {
                    recordDiagnostic("Gap disabled. Advancing immediately.")
                }

                // Send Next Track at zero, then fade back up before starting the play clock.
                phase = .changingTrack
                try MediaKey.nextTrack.post()
                recordDiagnostic("Sent Next Track.")
                try await fadeIn()
                guard restoreVolume() else { return }
                beginPlaying(for: play)
            }
        } catch {
            guard !Task.isCancelled else { return }
            status = error.localizedDescription
            recordDiagnostic("Playback workflow stopped. \(error.localizedDescription)", isError: true)
            _ = restoreVolume()
        }
    }

    private func beginPlaying(for duration: Duration) {
        phaseDuration = duration
        phaseStart = .now
        phase = .playing
        recordDiagnostic("Play timer reset to 0:00. Play duration: \(duration.components.seconds) seconds.")
    }

    func recordClockTick(_ elapsed: String) {
        guard elapsed != "0:00", phase == .playing || phase == .gap else { return }
        recordDiagnostic("\(phase == .gap ? "Gap" : "Play") timer: \(elapsed).")
    }

    private func playPhase(from start: ContinuousClock.Instant, duration: Duration) async throws {
        // Use the play clock's deadline so the fade fits inside the selected duration.
        let fadeDuration = min(.seconds(2), duration)
        let deadline = start.advanced(by: duration)
        let fadeStart = start.advanced(by: duration - fadeDuration)
        try await Task.sleep(until: fadeStart, clock: .continuous)
        try Task.checkCancellation()
        let output = try OutputVolume()
        volumeBeforeFade = output
        recordDiagnostic("Saved volume: \(output.level.formatted(.percent)) (device \(output.device)).")
        recordDiagnostic("Fading to zero over the last \(fadeDuration.components.seconds) seconds of Play.")
        let steps = Int(fadeDuration / .milliseconds(50))

        for step in 1..<steps {
            let stepDeadline = fadeStart.advanced(by: fadeDuration * step / steps)
            try await Task.sleep(until: stepDeadline, clock: .continuous)
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            if remaining <= .zero { break }
            try output.set(output.level * Float32(remaining / fadeDuration))
        }
        try await Task.sleep(until: deadline, clock: .continuous)
        try Task.checkCancellation()
        try output.set(0)
        recordDiagnostic("Play deadline reached. Set volume to 0%.")
    }

    private func restoreVolume() -> Bool {
        guard let output = volumeBeforeFade else { return true }
        recordDiagnostic("Restoring \(output.level.formatted(.percent)) on device \(output.device). Current output device: \(OutputVolume.defaultDevice()).")
        do {
            try output.restore()
        } catch {
            recordDiagnostic("Volume restore failed. \(error.localizedDescription)", isError: true)
            return false
        }
        volumeBeforeFade = nil
        guard diagnosticsOpen else { return true }
        if let readback = output.readLevel() {
            let mute = OutputVolume.readMute(output.device).map { $0 == 0 ? "off" : "on" } ?? "unavailable"
            recordDiagnostic("Restore readback: \(readback.formatted(.percent)); mute: \(mute).")
        } else {
            recordDiagnostic("macOS accepted the restore, but the volume could not be read back.", isError: true)
        }
        return true
    }

    private func fadeIn() async throws {
        guard let output = volumeBeforeFade else { return }
        let start = ContinuousClock.now
        let duration = Duration.milliseconds(500)
        recordDiagnostic("Fading in over half a second.")
        for step in 1..<10 {
            let stepDeadline = start.advanced(by: duration * step / 10)
            try await Task.sleep(until: stepDeadline, clock: .continuous)
            try Task.checkCancellation()
            let elapsed = start.duration(to: .now)
            if elapsed >= duration { break }
            do {
                try output.set(output.level * Float32(elapsed / duration))
            } catch {
                recordDiagnostic("Fade-in write failed. \(error.localizedDescription)", isError: true)
                break
            }
        }
        try await Task.sleep(until: start.advanced(by: duration), clock: .continuous)
        try Task.checkCancellation()
    }

    func setDiagnosticsOpen(_ isOpen: Bool) {
        diagnosticsOpen = isOpen
        if !isOpen { diagnostics = "" }
    }

    private func recordDiagnostic(_ message: @autoclosure () -> String, isError: Bool = false) {
        guard diagnosticsOpen else { return }
        let message = message()
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        diagnostics += "\(timestamp)  \(message)\n"
        if isError {
            volumeLog.error("\(message, privacy: .public)")
        } else {
            volumeLog.info("\(message, privacy: .public)")
        }
    }
}

private struct OutputVolume {
    let device: AudioDeviceID
    let level: Float32
    private let volumeAddress: AudioObjectPropertyAddress
    private let savedMute: UInt32?

    static var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func defaultDevice() -> AudioDeviceID {
        var output = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultOutput = defaultOutputAddress
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &defaultOutput, 0, nil, &size, &output
        )
        return result == noErr ? output : AudioDeviceID(kAudioObjectUnknown)
    }

    static func isSilenced(_ device: AudioDeviceID) -> Bool {
        (readMute(device) ?? 0) != 0 || readLevel(device) == 0
    }

    static func readMute(_ device: AudioDeviceID) -> UInt32? {
        var mute = muteAddress
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(device, &mute),
              AudioObjectGetPropertyData(device, &mute, 0, nil, &size, &muted) == noErr else {
            return nil
        }
        return muted
    }

    private static func readLevel(_ device: AudioDeviceID, at property: AudioObjectPropertyAddress = Self.address) -> Float32? {
        var address = property
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else {
            return nil
        }
        return volume
    }

    func readLevel() -> Float32? {
        Self.readLevel(device, at: volumeAddress)
    }

    init() throws {
        let output = Self.defaultDevice()
        guard output != kAudioObjectUnknown else {
            throw VolumeError("Could not find the current audio output.")
        }

        // Use the device's main volume control when it exposes one.
        var address = Self.address
        address.mSelector = kAudioDevicePropertyVolumeScalar
        if !Self.canSetVolume(output, at: &address) {
            address = Self.address
        }
        guard Self.canSetVolume(output, at: &address) else {
            throw VolumeError("The current audio output has no adjustable system volume.")
        }
        guard let volume = Self.readLevel(output, at: address) else {
            throw VolumeError("Could not read the current output volume.")
        }
        device = output
        level = volume
        volumeAddress = address
        savedMute = Self.readMute(output)
    }

    private static func canSetVolume(_ device: AudioDeviceID, at address: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr
            && settable.boolValue
    }

    func set(_ level: Float32) throws {
        try set(level, at: volumeAddress)
    }

    private func set(_ level: Float32, at property: AudioObjectPropertyAddress) throws {
        var address = property
        var volume = level
        let result = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume
        )
        guard result == noErr else {
            throw VolumeError("Could not set the output volume (Core Audio error \(result)).")
        }
    }

    func restore() throws {
        do {
            try set(level)
            if level > 0, readLevel() == 0 {
                throw VolumeError("The output volume stayed at zero after restoration.")
            }
        } catch {
            var fallback = Self.address
            if fallback.mSelector == volumeAddress.mSelector {
                fallback.mSelector = kAudioDevicePropertyVolumeScalar
            }
            guard Self.canSetVolume(device, at: &fallback) else { throw error }
            try set(level, at: fallback)
            if level > 0, Self.readLevel(device, at: fallback) == 0 {
                throw VolumeError("The output volume stayed at zero after both restore attempts.")
            }
        }
        guard var mute = savedMute, let currentMute = Self.readMute(device), mute != currentMute else { return }
        var address = Self.muteAddress
        let result = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &mute
        )
        guard result == noErr else {
            throw VolumeError("Could not restore the output mute state (Core Audio error \(result)).")
        }
    }
}

private struct VolumeError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
