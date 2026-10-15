import Foundation

package struct MacClippySnippetFocusIdentity: Equatable, Hashable, Sendable {
    package let processIdentifier: Int32
    package let elementIdentity: UInt64

    package init(processIdentifier: Int32, elementIdentity: UInt64) {
        self.processIdentifier = processIdentifier
        self.elementIdentity = elementIdentity
    }
}

package struct MacClippySnippetTextSelection: Equatable, Sendable {
    package let location: Int
    package let length: Int

    package init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

package struct MacClippySnippetFocusContext: Equatable, Sendable {
    package let identity: MacClippySnippetFocusIdentity
    package let selection: MacClippySnippetTextSelection?

    package init(identity: MacClippySnippetFocusIdentity, selection: MacClippySnippetTextSelection?) {
        self.identity = identity
        self.selection = selection
    }
}

package protocol MacClippySnippetFocusContextSource: AnyObject {
    var cachedIdentity: MacClippySnippetFocusIdentity? { get }
    var cachedSelection: MacClippySnippetTextSelection? { get }

    func currentIdentity() -> MacClippySnippetFocusIdentity?
    func currentContext() -> MacClippySnippetFocusContext?
    func start(onChange: @escaping () -> Void)
    func stop()
    func invalidateAndRefresh()
    func noteInputEvent()
    func noteInputText(_ text: String)
}

package extension MacClippySnippetFocusContextSource {
    var cachedSelection: MacClippySnippetTextSelection? { nil }

    func currentContext() -> MacClippySnippetFocusContext? {
        currentIdentity().map { MacClippySnippetFocusContext(identity: $0, selection: nil) }
    }

    func noteInputEvent() {}
    func noteInputText(_ text: String) { _ = text }
}
