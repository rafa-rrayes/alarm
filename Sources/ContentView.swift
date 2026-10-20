import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var controller: AlarmController
    @Bindable var settings: AlarmSettings

    private var isIdle: Bool { controller.phase == .idle }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                if !controller.hasAccessibility { permissionBanner }
                if let message = controller.errorMessage {
                    banner(message, icon: "exclamationmark.triangle.fill", tint: .red)
                }
                if let message = controller.warningMessage {
                    banner(message, icon: "info.circle.fill", tint: .orange)
                }
                settingsRows
                toggles
            }
            .padding(16)
            Divider()
            footer
        }
        // Only the width is ours to pick — a menu bar panel takes its height from
        // its content, so it stays tight when there's no banner to show.
        .frame(width: 360)
        .onAppear { controller.refreshPermission() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            if isIdle {
                Picker("", selection: $settings.mode) {
                    ForEach(AlarmSettings.ScheduleMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                switch settings.mode {
                case .at:
                    DatePicker(
                        "", selection: $settings.timeAsDate, displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .font(.system(size: 30, weight: .light, design: .rounded))
                    .scaleEffect(1.35)
                    .padding(.vertical, 10)
                case .after:
                    countdownEditor
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let fireDate = controller.fireDate,
                       !Calendar.current.isDateInToday(fireDate) {
                        Text(fireDate.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 22, weight: .light, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Text(controller.fireDate ?? settings.timeAsDate, style: .time)
                        .font(.system(size: 40, weight: .thin, design: .rounded))
                        .monospacedDigit()
                }
            }

            Text(statusLine)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private var statusLine: String {
        switch controller.phase {
        case .idle:
            // Only the clock mode has a fixed answer; "in X" depends on when you arm.
            guard settings.mode == .at else { return "not armed" }
            return "not armed · next: \(Format.when(settings.fireDate()))"
        case .arming: return "getting the sound ready…"
        case .armed:
            let repeats = settings.repeats ? " · repeats \(Weekdays.summary(settings.repeatDays))" : ""
            return "rings \(Format.relative(controller.remaining))\(repeats)"
        case .firing: return "sounding — \(Format.clock(controller.blockRemaining)) left"
        }
    }

    // MARK: - Countdown

    private static let presets = [5, 10, 15, 30, 60, 120]

    private var countdownEditor: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Stepper(value: countdownHours, in: 0...23) {
                    unit(settings.countdownMinutes / 60, "h")
                }
                Stepper(value: countdownMinutesPart, in: 0...59) {
                    unit(settings.countdownMinutes % 60, "m")
                }
            }
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.self) { minutes in
                    Button(Format.duration(minutes)) { settings.countdownMinutes = minutes }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(settings.countdownMinutes == minutes ? .accentColor : nil)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func unit(_ value: Int, _ suffix: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(value)")
                .font(.system(size: 34, weight: .light, design: .rounded))
                .monospacedDigit()
            Text(suffix).foregroundStyle(.secondary)
        }
    }

    /// The hour and minute steppers each edit their half of one stored total.
    private var countdownHours: Binding<Int> {
        Binding(
            get: { settings.countdownMinutes / 60 },
            set: { settings.countdownMinutes = $0 * 60 + settings.countdownMinutes % 60 }
        )
    }

    private var countdownMinutesPart: Binding<Int> {
        Binding(
            get: { settings.countdownMinutes % 60 },
            set: { settings.countdownMinutes = settings.countdownMinutes / 60 * 60 + $0 }
        )
    }

    // MARK: - Repeat

    private var repeatRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(Weekdays.ordered, id: \.self) { weekday in
                    let isOn = settings.repeatDays.contains(weekday)
                    Button {
                        if isOn {
                            settings.repeatDays.remove(weekday)
                        } else {
                            settings.repeatDays.insert(weekday)
                        }
                    } label: {
                        Text(Weekdays.initial(weekday))
                            .font(.caption.weight(.semibold))
                            .frame(width: 24, height: 22)
                            .background(
                                isOn ? Color.accentColor : Color.secondary.opacity(0.15),
                                in: .capsule
                            )
                            .foregroundStyle(isOn ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .help(Weekdays.name(weekday))
                }
            }
            Text(Weekdays.summary(settings.repeatDays))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Options

    private var settingsRows: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
            if settings.mode == .at {
                GridRow {
                    Text("Repeat")
                    repeatRow
                }
            }

            GridRow {
                Text("Sound").gridColumnAlignment(.leading)
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $settings.source) {
                        ForEach(AlarmSettings.SoundSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    switch settings.source {
                    case .file: filePicker
                    case .folder: folderPicker
                    case .youtube: youtubeField
                    }
                }
            }

            GridRow {
                Text("Block for")
                Picker("", selection: $settings.duration) {
                    ForEach(AlarmSettings.durationChoices, id: \.self) { seconds in
                        Text(durationLabel(seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
            }

            GridRow {
                Text("Volume")
                HStack(spacing: 8) {
                    Slider(value: $settings.volume, in: 0...1)
                    Text("\(Int(settings.volume * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
        .disabled(!isIdle)
    }

    private var filePicker: some View {
        HStack(spacing: 8) {
            Button(settings.soundFileName ?? "Choose…") { chooseFile() }
                .lineLimit(1)
                .truncationMode(.middle)
            previewButton
        }
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    chooseFolder()
                } label: {
                    Label(settings.folderName ?? "Choose folder…", systemImage: "folder")
                }
                .lineLimit(1)
                .truncationMode(.middle)
                previewButton
            }
            if let name = controller.trackName, controller.isPreviewing || !isIdle {
                Label(name, systemImage: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Random songs, a new one whenever one ends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var youtubeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("YouTube URL", text: $settings.youtubeURL)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1)
                previewButton
            }
            if AudioEngine.ytDlpPath == nil {
                Text("yt-dlp not found — install it with `brew install yt-dlp`")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var previewButton: some View {
        Button {
            Task { await controller.togglePreview() }
        } label: {
            Image(systemName: controller.isPreviewing ? "stop.fill" : "play.fill")
        }
        .help(controller.isPreviewing ? "Stop preview" : "Preview at current volume")
        .disabled(!isIdle)
    }

    // MARK: - Toggles

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Cover the screen", isOn: $settings.showOverlay)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Let me stop it early", isOn: $settings.escapeEnabled)
                if settings.escapeEnabled {
                    Stepper(
                        "Hold ⎋ for \(Int(settings.escapeHold))s",
                        value: $settings.escapeHold, in: 2...30, step: 1
                    )
                    .padding(.leading, 20)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Keep awake with the lid closed", isOn: $settings.blockLidSleep)
                if settings.blockLidSleep {
                    Text("No prompt if LidLock's sudo rule is installed; otherwise asks for your admin password when you arm.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!isIdle)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(role: isIdle ? nil : .destructive) {
                if isIdle {
                    Task { await controller.arm() }
                } else {
                    controller.disarm()
                }
            } label: {
                Group {
                    if controller.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(isIdle ? "Arm alarm" : "Disarm")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(controller.isBusy || (isIdle && !controller.canArm))
            .keyboardShortcut(.defaultAction)

            // An agent app has no app menu, so this is the only way out. It goes
            // through `terminate` rather than `exit` so an armed alarm still
            // gets its confirmation.
            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.large)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(16)
    }

    // MARK: - Banners

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                "Alarm needs Accessibility permission to block the keyboard and trackpad.",
                systemImage: "lock.fill"
            )
            .font(.callout)
            HStack {
                Button("Grant…") { controller.requestPermission() }
                Button("Open Settings") { openAccessibilitySettings() }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8))
    }

    private func banner(_ message: String, icon: String, tint: Color) -> some View {
        Label(message, systemImage: icon)
            .font(.callout)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: 8))
            .textSelection(.enabled)
    }

    // MARK: - Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        // Without this the open panel can open behind the frontmost app, since
        // clicking a menu bar item doesn't make us it.
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.setSoundFile(url)
            controller.errorMessage = nil
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            settings.setSoundFolder(url)
            controller.errorMessage = nil
        }
    }

    private func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    private func durationLabel(_ seconds: Int) -> String {
        seconds < 60
            ? "\(seconds) seconds"
            : (seconds == 60 ? "1 minute" : "\(seconds / 60) minutes")
    }
}
