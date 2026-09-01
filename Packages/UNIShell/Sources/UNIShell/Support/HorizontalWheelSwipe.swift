import AppKit
import SwiftUI

/// Encaminha a rolagem **horizontal** do mouse para a linha de swipe.
///
/// Na lista, o arraste com o botão já revela ações; a roda/Magic Mouse na
/// horizontal ia para a `ScrollView` vertical e virava nada. Só o eixo
/// dominante em X é consumido; a rolagem vertical da caixa continua.
///
/// O monitor local do AppKit corre no fio da UI. A sessão é main-thread only;
/// `@unchecked Sendable` é o contrato com o bloco do `NSEvent`.
final class WheelSwipeSession: @unchecked Sendable {
    static let shared = WheelSwipeSession()

    private var monitor: Any?
    private var owner: String?
    private var onDelta: ((CGFloat) -> Void)?
    private var onEnded: (() -> Void)?
    private var endWorkItem: DispatchWorkItem?

    private init() {}

    func attach(
        id: String,
        onDelta: @escaping (CGFloat) -> Void,
        onEnded: @escaping () -> Void
    ) {
        owner = id
        self.onDelta = onDelta
        self.onEnded = onEnded
        if monitor != nil { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.consume(event) ? nil : event
        }
    }

    func detach(id: String) {
        guard owner == id else { return }
        endWorkItem?.cancel()
        owner = nil
        onDelta = nil
        onEnded = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func consume(_ event: NSEvent) -> Bool {
        var dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        guard abs(dx) >= 1.5 * abs(dy), abs(dx) > 0.35 else { return false }
        // Rolagem natural inverte o delta; o arraste com o botão não.
        // Sem isto, o Magic Mouse ia para um lado e a linha para o outro.
        if event.isDirectionInvertedFromDevice { dx = -dx }
        if !event.hasPreciseScrollingDeltas { dx *= 12 }
        onDelta?(dx)
        let ended = event.phase == .ended
            || event.phase == .cancelled
            || event.momentumPhase == .ended
            || event.momentumPhase == .cancelled
        endWorkItem?.cancel()
        if ended {
            onEnded?()
        } else {
            let work = DispatchWorkItem { [weak self] in
                self?.onEnded?()
            }
            endWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        }
        return true
    }
}
