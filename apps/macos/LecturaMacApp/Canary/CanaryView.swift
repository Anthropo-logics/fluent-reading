import SwiftUI

struct CanaryView: View {
  @State private var model = CanaryViewModel()

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "waveform.circle.fill")
        .font(.system(size: 44))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)

      switch model.state {
      case .loading:
        ProgressView("canary.loading")
      case .ready(let event):
        Text("canary.ready")
          .font(.headline)
        Text(event.result?.canary?.message ?? "")
          .accessibilityIdentifier("canary.result")
        Text(event.result?.canary?.coreVersion ?? "")
          .font(.caption.monospaced())
      case .failed(let failure):
        Text("canary.error.title")
          .font(.headline)
        Text(LocalizedStringKey(failure.messageKey))
          .accessibilityIdentifier("canary.error")
        Text(failure.code)
          .font(.caption.monospaced())
      }
    }
    .padding(32)
    .frame(minWidth: 420, minHeight: 240)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("canary.status")
    .task {
      await model.load()
    }
  }
}
