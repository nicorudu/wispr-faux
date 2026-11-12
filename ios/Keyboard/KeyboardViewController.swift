import SwiftUI
import UIKit

/// The Wispr Faux keyboard: a mic bar above a plain QWERTY layout.
///
/// The keyboard can't record (iOS doesn't give keyboards the microphone) and is far too small
/// for Whisper, so the mic button drives the app's background session through `SessionChannel`
/// and types the transcript it sends back.
final class KeyboardViewController: UIInputViewController {
    private var model: KeyboardModel!
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        model = KeyboardModel(controller: self)
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        let height = view.heightAnchor.constraint(equalToConstant: KeyboardView.height)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        heightConstraint = height
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.appear()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappear()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.textDidChange()
    }

    /// Opens the Wispr Faux app. Keyboards have no API for this; walking the responder chain
    /// to the application object is the long-standing way keyboards do it.
    func openApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                // Called through the runtime: the method is marked unavailable to extensions at
                // compile time, but the application object answers it.
                let selector = NSSelectorFromString("openURL:options:completionHandler:")
                guard application.responds(to: selector), let method = application.method(for: selector) else { return }
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                unsafeBitCast(method, to: Open.self)(application, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}
