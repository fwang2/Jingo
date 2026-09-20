import Combine
import Common
import ComposableArchitecture
import FluidGradient
import Inject
import SwiftUI

// MARK: - RootView

@MainActor
struct RootView: View {
  @Bindable var store: StoreOf<Root>
  @State var isGoToNewRecordingPopupPresented = false

  @Namespace private var namespace

  var body: some View {
    Group {
      NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
        RecordScreenView(store: store.scope(state: \.recordScreen, action: \.recordScreen))
          .background {
            FluidGradient(
              blobs: [Color(hexString: "#000040"), Color(hexString: "#000030"), Color(hexString: "#000020")],
              highlights: [Color(hexString: "#1D004D"), Color(hexString: "#300055"), Color(hexString: "#100020")],
              speed: 0.2,
              blur: 0.75
            )
            .ignoresSafeArea()
          }
          .background(Color.DS.Background.primary)
      } destination: { store in
        switch store.case {
        case .list:
          RecordingListScreenView(store: self.store.scope(state: \.recordingListScreen, action: \.recordingListScreen))

        case .settings:
          SettingsScreenView(store: self.store.scope(state: \.settingsScreen, action: \.settingsScreen))

        case let .details(store):
          RecordingDetailsView(store: store)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        bottomBar
      }
      .accentColor(.white)
      .task {
        store.send(.task)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          store.send(.recordingListScreen(.task))
          store.send(.settingsScreen(.task))
          store.send(.recordScreen(.micSelector(.task)))
          store.send(.settingsScreen(.premiumFeaturesSection(.onTask)))
          store.send(.settingsScreen(.updateInfo))
        }
      }
      .popover(
        present: $isGoToNewRecordingPopupPresented,
        attributes: {
          $0.position = .absolute(originAnchor: .top, popoverAnchor: .bottom)
          $0.presentation = .init(animation: .hardShowHide(), transition: .move(edge: .bottom).combined(with: .opacity))
          $0.dismissal = .init(
            animation: .hardShowHide(),
            transition: .move(edge: .bottom).combined(with: .opacity),
            mode: [.dragDown, .tapOutside]
          )
        }
      ) {
        VStack(spacing: .grid(4)) {
          Text("View the new recording?")
            .textStyle(.label)
            .foregroundColor(.DS.Text.base)

          Button("View Recording") {
            store.send(.goToNewRecordingButtonTapped)
          }.secondaryButtonStyle()
        }
        .padding(.grid(3))
        .cardStyle()
      }
      .bind($store.isGoToNewRecordingPopupPresented, to: $isGoToNewRecordingPopupPresented)
      .onChange(of: isGoToNewRecordingPopupPresented) { _, isPresented in
        if isPresented {
          withAnimation(.spring.delay(5)) {
            isGoToNewRecordingPopupPresented = false
          }
        }
      }
    }
  }

  var bottomBar: some View {
    HStack(spacing: 0) {
      bottomBarButton("Home", systemImage: "house", action: .homeButtonTapped)
      bottomBarButton("Recordings", systemImage: "waveform", action: .recordingListButtonTapped)
      bottomBarButton("Audio", systemImage: "mic.circle.fill", action: .audioButtonTapped, isPrimary: true)
      bottomBarButton("Settings", systemImage: "gearshape", action: .settingsButtonTapped)
    }
    .padding(.horizontal, .grid(2))
    .padding(.vertical, .grid(1))
    .background(.ultraThinMaterial)
    .overlay(alignment: .top) { Divider() }
  }

  private func bottomBarButton(
    _ title: String,
    systemImage: String,
    action: Root.Action,
    isPrimary: Bool = false
  ) -> some View {
    Button { store.send(action) } label: {
      VStack(spacing: 3) {
        Image(systemName: systemImage)
          .font(isPrimary ? .title2 : .body)
          .foregroundStyle(isPrimary ? Color.DS.Text.accent : Color.DS.Text.base)
        Text(title)
          .font(.caption2)
          .foregroundStyle(Color.DS.Text.base)
      }
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
