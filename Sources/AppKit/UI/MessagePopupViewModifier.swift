import ComposableArchitecture
import Foundation
import Popovers
import SwiftUI

// MARK: - MessagePopupViewModifier

struct MessagePopupViewModifier<ButtonAction>: ViewModifier {
  @Binding var isPresented: Bool
  var alertState: AlertState<ButtonAction>?
  var sendAction: (ButtonAction) -> Void
  @SwiftUI.State var expanding = false

  func body(content: Content) -> some View {
    content.popover(
      present: $isPresented,
      attributes: {
        $0.blocksBackgroundTouches = true
        $0.rubberBandingMode = .none
        $0.position = .relative(
          popoverAnchors: [
            .center,
          ]
        )
        $0.presentation.animation = .easeOut(duration: 0.15)
        $0.dismissal.mode = .none
        $0.onTapOutside = {
          withAnimation(.easeIn(duration: 0.15)) {
            expanding = true
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeOut(duration: 0.4)) {
              expanding = false
            }
          }
        }
      }
    ) {
      AlertViewPopover(
        present: $isPresented,
        expanding: $expanding,
        alertState: alertState,
        sendAction: sendAction
      )
    } background: {
      Color.black.opacity(0.1)
    }
  }
}

// MARK: - AlertViewPopover

struct AlertViewPopover<ButtonAction>: View {
  @Binding var present: Bool
  @Binding var expanding: Bool
  var alertState: AlertState<ButtonAction>?
  var sendAction: (ButtonAction) -> Void

  /// the initial animation
  @SwiftUI.State var scaled = true

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 6) {
        Text(alertState?.title ?? TextState(""))
          .fontWeight(.medium)
          .multilineTextAlignment(.center)

        Text(alertState?.message ?? TextState(""))
          .multilineTextAlignment(.center)
      }
      .padding()

      Divider()

      HStack {
        if alertState?.buttons.map(\.role).contains(.cancel) == false {
          Button(role: .cancel) {
            present = false
          } label: {
            Text("Cancel")
          }
        }
        ForEach(alertState?.buttons ?? []) { button in
          Button(role: button.role.map(ButtonRole.init)) {
            switch button.action.type {
            case let .send(action):
              if let action {
                sendAction(action)
              }

            case let .animatedSend(action, animation):
              if let action {
                withAnimation(animation) {
                  sendAction(action)
                }
              }
            }
          } label: {
            Text(button.label)
          }
        }
      }
      .buttonStyle(Templates.AlertButtonStyle())
    }
    .background(Color(.systemBackground))
    .cornerRadius(16)
    .popoverShadow(shadow: .system)
    .frame(width: 260)
    .scaleEffect(expanding ? 1.05 : 1)
    .scaleEffect(scaled ? 2 : 1)
    .opacity(scaled ? 0 : 1)
    .onAppear {
      withAnimation(.spring(
        response: 0.4,
        dampingFraction: 0.9,
        blendDuration: 1
      )) {
        scaled = false
      }
    }
  }
}
