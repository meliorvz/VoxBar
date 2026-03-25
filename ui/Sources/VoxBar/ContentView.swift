import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: ArticleTTSViewModel
    @ObservedObject private var playback: PlaybackController

    @State private var showDetails = false
    @State private var showVoicePalette = false
    @State private var isSourceExpanded = true
    @State private var isSettingsExpanded = false
    @State private var isRecentExpanded = false

    init(viewModel: ArticleTTSViewModel) {
        self.viewModel = viewModel
        _playback = ObservedObject(wrappedValue: viewModel.playback)
    }

    var body: some View {
        ZStack {
            BackgroundSurface()

            VStack(spacing: 8) {
                compactPlayer
                sourceSection
                settingsSection
                recentSection
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        .frame(width: 470)
        .onAppear {
            viewModel.onAppear()
            isSourceExpanded = trimmedInput.isEmpty
        }
        .onChange(of: viewModel.isGenerating) { _, isGenerating in
            if isGenerating {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                    isSourceExpanded = true
                }
            }
        }
        .onChange(of: viewModel.progress.phase) { _, phase in
            if phase == .ready {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                    isSourceExpanded = false
                    isSettingsExpanded = false
                    isRecentExpanded = false
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: viewModel.isGenerating)
        .animation(.easeInOut(duration: 0.18), value: viewModel.progress.message)
        .animation(.easeInOut(duration: 0.18), value: viewModel.history.count)
        .animation(.easeInOut(duration: 0.18), value: viewModel.selectedRecordID)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                        isSourceExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: isSourceExpanded ? "square.and.pencil" : "plus.square")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Source")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(mutedInk)
                                .textCase(.uppercase)
                            Text(sourceSectionSubtitle)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(ink.opacity(0.88))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: isSourceExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(mutedInk)
                    }
                }
                .buttonStyle(.plain)

                statusBadge

                Button {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        viewModel.inputText = value
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                            isSourceExpanded = true
                        }
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(UtilityIconButtonStyle())
            }

            if isSourceExpanded {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $viewModel.inputText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ink)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(height: editorHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.white.opacity(0.48))
                        )

                    if trimmedInput.isEmpty {
                        Text("Paste a link or plain text")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(mutedInk.opacity(0.82))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

                if shouldShowStatus {
                    inlineStatus
                }

                HStack {
                    Button("Clear") {
                        viewModel.inputText = ""
                    }
                    .buttonStyle(TextActionButtonStyle())
                    .disabled(trimmedInput.isEmpty || viewModel.isGenerating)

                    Spacer()

                    Button {
                        viewModel.generate()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: viewModel.isGenerating ? "hourglass" : "waveform.path")
                            Text(viewModel.isGenerating ? "Generating" : "Generate")
                        }
                    }
                    .buttonStyle(PrimaryCapsuleButtonStyle())
                    .disabled(trimmedInput.isEmpty || viewModel.isGenerating)
                }
            }
        }
        .padding(14)
        .background(SurfaceShell())
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                        isSettingsExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Voice & Speed")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(mutedInk)
                                .textCase(.uppercase)
                            Text("\(selectedVoiceProfile.displayName) • \(viewModel.selectedSpeedLabel)")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(ink.opacity(0.88))
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: isSettingsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(mutedInk)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.toggleFavoriteCurrentSetting()
                } label: {
                    Image(systemName: viewModel.currentSettingIsFavorited ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(UtilityIconButtonStyle())
            }

            if isSettingsExpanded {
                HStack(alignment: .top, spacing: 10) {
                    voiceControl
                    speedControl
                }
            }
        }
        .padding(14)
        .background(SurfaceShell())
    }

    private var statusBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(viewModel.isGenerating ? accent : mutedInk.opacity(0.38))
                .frame(width: 7, height: 7)
            Text(statusLabel)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(mutedInk)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.56))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.58), lineWidth: 1)
        )
    }

    private var voiceControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Voice")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(mutedInk)
                .textCase(.uppercase)

            voiceButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var speedControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Speed")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(mutedInk)
                    .textCase(.uppercase)

                Spacer()

                Text(viewModel.selectedSpeedLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ink)
            }

            HStack(spacing: 8) {
                Button {
                    viewModel.decreaseSpeed()
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(UtilityIconButtonStyle())
                .disabled(viewModel.selectedSpeed <= ArticleTTSViewModel.minSpeed)

                Slider(
                    value: Binding(
                        get: { viewModel.selectedSpeed },
                        set: { viewModel.setSelectedSpeed($0) }
                    ),
                    in: ArticleTTSViewModel.minSpeed...ArticleTTSViewModel.maxSpeed,
                    step: ArticleTTSViewModel.speedStep
                )
                .tint(accent)

                Button {
                    viewModel.increaseSpeed()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(UtilityIconButtonStyle())
                .disabled(viewModel.selectedSpeed >= ArticleTTSViewModel.maxSpeed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var voiceButton: some View {
        Button {
            showVoicePalette.toggle()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedVoiceProfile.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ink)
                    Text(selectedVoiceProfile.languageLabel)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(mutedInk)
                }

                Spacer(minLength: 6)
                VoiceChip(profile: selectedVoiceProfile)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(mutedInk)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.56))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.58), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showVoicePalette, arrowEdge: .top) {
            voicePalette
        }
    }

    private var voicePalette: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose Voice")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(mutedInk)
                        .textCase(.uppercase)
                    Text("Preview uses \(viewModel.selectedSpeedLabel)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(mutedInk)
                }

                Spacer()
            }

            if !viewModel.favoriteSettings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Starred")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(mutedInk)
                        .textCase(.uppercase)

                    LazyVStack(spacing: 6) {
                        ForEach(viewModel.favoriteSettings.prefix(ArticleTTSViewModel.maxFavoriteSettings)) { favorite in
                            favoriteSettingRow(favorite)
                        }
                    }
                }
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 6) {
                    ForEach(voiceProfiles, id: \.id) { profile in
                        voiceRow(profile)
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(width: 334, height: 248)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.97, green: 0.95, blue: 0.92).opacity(0.98))
        )
    }

    private func favoriteSettingRow(_ favorite: FavoriteVoiceSetting) -> some View {
        let profile = VoiceProfile(id: favorite.voice)
        let isCurrent = favorite.voice == viewModel.selectedVoice && favorite.speed == viewModel.selectedSpeed

        return HStack(spacing: 8) {
            Button {
                viewModel.applyFavorite(favorite)
                showVoicePalette = false
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isCurrent ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(ink)
                        Text("\(profile.languageLabel) • \(speedLabel(for: favorite.speed))")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(mutedInk)
                    }

                    Spacer()

                    VoiceChip(profile: profile)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isCurrent ? Color.white.opacity(0.84) : Color.white.opacity(0.46))
                )
            }
            .buttonStyle(.plain)

            Button {
                viewModel.removeFavorite(favorite)
            } label: {
                Image(systemName: "star.slash")
                    .font(.system(size: 12.5, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(UtilityIconButtonStyle())
        }
    }

    private func voiceRow(_ profile: VoiceProfile) -> some View {
        HStack(spacing: 8) {
            Button {
                viewModel.setSelectedVoice(profile.id)
                showVoicePalette = false
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: profile.gender.symbolName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(ink)
                        Text(profile.languageLabel)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(mutedInk)
                    }

                    Spacer()

                    VoiceChip(profile: profile)

                    if profile.id == viewModel.selectedVoice {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(accent)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(profile.id == viewModel.selectedVoice ? Color.white.opacity(0.84) : Color.white.opacity(0.46))
                )
            }
            .buttonStyle(.plain)

            Button {
                viewModel.previewVoice(profile.id)
            } label: {
                Group {
                    if viewModel.previewingVoiceID == profile.id {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12.5, weight: .bold))
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(UtilityIconButtonStyle())
            .disabled(viewModel.previewingVoiceID != nil && viewModel.previewingVoiceID != profile.id)
        }
    }

    private var inlineStatus: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(viewModel.progress.message)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ink)

                Spacer()

                if let fraction = viewModel.progress.fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(mutedInk)
                }

                if !viewModel.progress.logLines.isEmpty || viewModel.progress.lastError != nil {
                    Button(showDetails ? "Less" : "More") {
                        showDetails.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(accent)
                }
            }

            if let fraction = viewModel.progress.fraction {
                ProgressView(value: fraction)
                    .tint(accent)
            }

            Text(viewModel.progress.lastError ?? viewModel.progress.detail)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(viewModel.progress.lastError == nil ? mutedInk : errorTint)
                .lineLimit(showDetails ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)

            if showDetails && !viewModel.progress.logLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.progress.logLines.suffix(4), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(mutedInk)
                    }
                }
                .padding(.top, 1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.28))
        )
    }

    private var compactPlayer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: playback.isPlaying ? "waveform.circle.fill" : "music.note")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(accent)
                        Text("Now Playing")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(mutedInk)
                            .textCase(.uppercase)
                    }

                    if let playerTitle {
                        Text(playerTitle)
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(ink)
                            .lineLimit(1)
                    } else {
                        Text("No audio selected")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ink.opacity(0.72))
                    }

                    Text(playerSubtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(mutedInk)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if let selected = viewModel.selectedRecord {
                    Text(selected.sourceKind == .url ? "Link" : "Text")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(mutedInk)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.46))
                        )
                }
            }

            HStack {
                Spacer()

                HStack(spacing: 16) {
                    TransportButton(symbol: "gobackward.15", size: 42) {
                        viewModel.rewind()
                    }
                    .disabled(!canControlPlayback)

                    Button {
                        viewModel.togglePlayback()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 21, weight: .bold))
                            .frame(width: 64, height: 64)
                    }
                    .buttonStyle(PrimaryRoundButtonStyle())
                    .disabled(!canControlPlayback)

                    TransportButton(symbol: "goforward.30", size: 42) {
                        viewModel.skipForward()
                    }
                    .disabled(!canControlPlayback)
                }

                Spacer()
            }

            if playback.duration > 0 {
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: {
                                guard playback.duration > 0 else { return 0 }
                                return playback.currentTime / playback.duration
                            },
                            set: { playback.seek(to: $0) }
                        )
                    )
                    .tint(accent)

                    HStack {
                        Text(formattedTime(playback.currentTime))
                        Spacer()
                        Text(formattedTime(playback.duration))
                    }
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(mutedInk)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.34))
        )
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                    isRecentExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recent")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(mutedInk)
                            .textCase(.uppercase)
                        Text(recentSectionSubtitle)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(ink.opacity(0.88))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isRecentExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(mutedInk)
                }
            }
            .buttonStyle(.plain)

            if isRecentExpanded {
                if viewModel.history.isEmpty {
                    Text("Generated items will appear here.")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(mutedInk)
                        .padding(.vertical, 6)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(viewModel.history.prefix(8)) { record in
                                historyRow(record)
                            }
                        }
                    }
                    .frame(height: recentListHeight)
                }
            }
        }
        .padding(14)
        .background(SurfaceShell())
    }

    private func historyRow(_ record: GenerationRecord) -> some View {
        let profile = VoiceProfile(id: record.voice)
        let isSelected = viewModel.selectedRecordID == record.id
        let isPlayingRecord = isSelected && playback.currentTitle == record.title

        return HStack(spacing: 10) {
            Button {
                viewModel.play(record)
            } label: {
                Image(systemName: isPlayingRecord ? "speaker.wave.2.fill" : "play.fill")
                    .font(.system(size: 12.5, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(UtilityIconButtonStyle())

            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(1)

                if let metadataSummary = record.metadataSummary, !metadataSummary.isEmpty {
                    Text(metadataSummary)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(mutedInk)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 8) {
                        Text(profile.displayName)
                        MetaDot()
                        Text(record.sourceKind == .url ? "Link" : "Text")
                        MetaDot()
                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(mutedInk)
                    .lineLimit(1)
                }
            }

            Spacer()

            if isSelected {
                Text(playback.isPlaying ? "Playing" : "Selected")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(isPlayingRecord ? accent : mutedInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.56))
                    )
            }

            Button(role: .destructive) {
                viewModel.delete(record)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(UtilityIconButtonStyle())
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.28) : Color.white.opacity(0.10))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.play(record)
        }
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func speedLabel(for value: Double) -> String {
        if value.rounded() == value {
            return String(format: "%.1fx", value)
        }
        return String(format: "%.2fx", value)
    }

    private var trimmedInput: String {
        viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var looksLikeURL: Bool {
        trimmedInput.lowercased().hasPrefix("http://") || trimmedInput.lowercased().hasPrefix("https://")
    }

    private var sourceModeLabel: String {
        if trimmedInput.isEmpty {
            return "Paste link or text"
        }
        return looksLikeURL ? "Article link" : "Raw text"
    }

    private var statusLabel: String {
        if viewModel.isGenerating {
            return "Running"
        }
        if viewModel.progress.phase == .failed {
            return "Issue"
        }
        return "Ready"
    }

    private var shouldShowStatus: Bool {
        viewModel.isGenerating || viewModel.progress.phase == .failed || viewModel.progress.phase == .ready
    }

    private var selectedVoiceProfile: VoiceProfile {
        VoiceProfile(id: viewModel.selectedVoice)
    }

    private var voiceProfiles: [VoiceProfile] {
        let source = viewModel.availableVoices.isEmpty ? [viewModel.selectedVoice] : viewModel.availableVoices
        return source.map { VoiceProfile(id: $0) }.sorted { $0.displayName < $1.displayName }
    }

    private var editorHeight: CGFloat {
        let content = trimmedInput
        guard !content.isEmpty else { return 50 }

        let explicitLines = max(viewModel.inputText.split(separator: "\n", omittingEmptySubsequences: false).count, 1)
        let wrappedLines = max((content.count / 58) + 1, 1)
        let estimatedLines = min(max(explicitLines, wrappedLines), 6)
        return min(max(CGFloat(estimatedLines) * 20 + 18, 74), 158)
    }

    private var canControlPlayback: Bool {
        playback.currentTitle != nil || viewModel.selectedRecord != nil
    }

    private var playerTitle: String? {
        playback.currentTitle ?? viewModel.selectedRecord?.title
    }

    private var playerSubtitle: String {
        if let subtitle = playback.currentSubtitle {
            return subtitle
        }
        if let record = viewModel.selectedRecord {
            if let metadataSummary = record.metadataSummary, !metadataSummary.isEmpty {
                return metadataSummary
            }
            let profile = VoiceProfile(id: record.voice)
            return "\(profile.displayName) • \(record.sourceKind == .url ? "Link" : "Text")"
        }
        return "Choose a generation or preview a voice."
    }

    private var sourceSectionSubtitle: String {
        if viewModel.isGenerating {
            return viewModel.progress.message
        }
        if trimmedInput.isEmpty {
            return "New from link or text"
        }
        return sourceModeLabel + " • " + String(trimmedInput.prefix(42))
    }

    private var recentSectionSubtitle: String {
        guard !viewModel.history.isEmpty else {
            return "No saved generations yet"
        }
        if let first = viewModel.history.first {
            return "\(viewModel.history.count) items • \(first.title)"
        }
        return "\(viewModel.history.count) items"
    }

    private var recentListHeight: CGFloat {
        CGFloat(min(viewModel.history.prefix(8).count, 4)) * 58
    }
}

private struct BackgroundSurface: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.95, green: 0.92, blue: 0.87),
                Color(red: 0.89, green: 0.91, blue: 0.93),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color(red: 0.12, green: 0.25, blue: 0.37).opacity(0.11))
                .frame(width: 210, height: 210)
                .offset(x: 75, y: -80)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(Color(red: 0.79, green: 0.66, blue: 0.49).opacity(0.10))
                .frame(width: 220, height: 220)
                .offset(x: -50, y: 90)
        }
    }
}

private struct SurfaceShell: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color(red: 0.97, green: 0.95, blue: 0.92).opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.58), lineWidth: 1)
            )
    }
}

private struct VoiceChip: View {
    let profile: VoiceProfile

    var body: some View {
        HStack(spacing: 6) {
            Badge(icon: profile.gender.symbolName, label: profile.gender.shortLabel)
            Badge(icon: "globe", label: profile.regionCode)
        }
    }
}

private struct Badge: View {
    let icon: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .bold))
            Text(label)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
        }
        .foregroundStyle(mutedInk)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.56))
        )
    }
}

private struct MetaDot: View {
    var body: some View {
        Circle()
            .fill(mutedInk.opacity(0.45))
            .frame(width: 3, height: 3)
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .frame(width: size, height: size)
        }
        .buttonStyle(UtilityIconButtonStyle())
    }
}

private struct PrimaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule(style: .continuous)
                    .fill(accent.opacity(configuration.isPressed ? 0.86 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct TextActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(mutedInk)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct PrimaryRoundButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white)
            .background(
                Circle()
                    .fill(accent.opacity(configuration.isPressed ? 0.86 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct SelectionCapsuleButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white : ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill((isSelected ? accent : Color.white.opacity(0.56)).opacity(configuration.isPressed ? 0.84 : 1))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isSelected ? accent.opacity(0.2) : Color.white.opacity(0.58), lineWidth: 1)
            )
    }
}

private struct UtilityIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ink)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.44 : 0.56))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.58), lineWidth: 1)
            )
    }
}

private let ink = Color(red: 0.16, green: 0.18, blue: 0.21)
private let mutedInk = Color(red: 0.39, green: 0.42, blue: 0.46)
private let accent = Color(red: 0.17, green: 0.41, blue: 0.68)
private let errorTint = Color(red: 0.72, green: 0.24, blue: 0.21)
