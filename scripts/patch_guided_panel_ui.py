from pathlib import Path

path = Path("mreader/ReaderView.swift")
text = path.read_text()
marker = "mreader.reader.guidedPanelAction"
if marker in text:
    print("Guided Panel action already present; nothing to patch.")
    raise SystemExit(0)

anchor = '''            if comic.isOCREnabled || comic.isAITranslationEnabled {
                HStack(spacing: 10) {
                    Spacer()
'''

insertion = '''            HStack(spacing: 10) {
                Spacer()

                Button {
                    guard readingMode != .guidedPanel else { return }
                    HapticManager.shared.play(.light)
                    readingModeRaw.wrappedValue = ReadingMode.guidedPanel.rawValue
                } label: {
                    Label("reader.mode.guidedPanel".localized, systemImage: "rectangle.split.2x2")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background {
                            Capsule()
                                .fill(
                                    readingMode == .guidedPanel
                                        ? Color.accentColor.opacity(0.88)
                                        : Color.white.opacity(0.10)
                                )
                        }
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    .white.opacity(readingMode == .guidedPanel ? 0.30 : 0.16),
                                    lineWidth: 0.5
                                )
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("reader.mode.guidedPanel".localized)
                .accessibilityIdentifier("mreader.reader.guidedPanelAction")
            }
            .frame(minHeight: 40)

'''

if anchor not in text:
    raise SystemExit("Expected Reader progress-action anchor was not found")

path.write_text(text.replace(anchor, insertion + anchor, 1))
print("ReaderView.swift patched.")
