import Foundation

// Pure policy for the mixed-content sequential queue paste path.
//
// Unlike MacClippyDockMultiPastePolicy (which merges a homogeneous text-
// compatible selection into one paste), queue paste processes the ordered
// selected IDs one at a time in visual order, injecting a separate Cmd+V per
// record so mixed selections (text + image + files) can each be consumed by
// the target app in turn. The only policy value this path needs is the settle
// delay waited between successful injections so the target app has time to
// consume each paste before the next pasteboard write overwrites it. The sleep
// is performed by the runtime off the main thread; the policy only names the
// value so it can be unit-tested without a timer.
public enum MacClippyQueuePastePolicy {
    // Seconds to wait between two successful paste injections so the target
    // app can consume the current pasteboard item before the next record
    // overwrites it. Long enough for a typical app to handle a paste event,
    // short enough that a multi-record queue does not feel slow. The runtime
    // sleeps off the main thread and never holds the store lock while sleeping.
    public static let settleInterval: TimeInterval = 0.12
}
