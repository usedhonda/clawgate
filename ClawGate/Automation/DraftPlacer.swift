import AppKit
import ApplicationServices
import Foundation

/// Context captured at Omakase trigger time, before the AI response arrives.
struct OmakaseContext {
    let bundleId: String
    let appName: String
    let pid: pid_t
    let isMessagingApp: Bool
}

/// Places AI-generated draft text into a target app's input field.
/// Safety guarantees:
///   - Never presses Enter (no auto-send)
///   - setValue() tried first (safe for Native/Qt apps)
///   - safePaste() only with 4-stage verification (Electron apps)
///   - Falls back to Summon tab display on any failure
enum DraftPlacer {

    enum PlaceResult {
        case placed
        case fallback
        case appNotRunning
    }

    /// Browser bundle IDs (shared with PetModel for context detection)
    static let browserBundles: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.brave.Browser",
        "company.thebrowser.Browser", // Arc
        "com.microsoft.edgemac",
    ]

    /// Place draft text into the target app's input field.
    /// Must be called from a background queue (BlockingWork.queue).
    static func placeDraft(text: String, context: OmakaseContext) -> PlaceResult {
        guard AXIsProcessTrusted() else {
            NSLog("[DraftPlacer] AX not trusted, falling back")
            return .fallback
        }

        let isBrowser = browserBundles.contains(context.bundleId)
        // Browser AX trees are deep — increase search depth
        let maxDepth = isBrowser ? 8 : 6
        let maxNodes = isBrowser ? 1200 : 500

        do {
            var placed = false
            try AXAppWindow.withWindow(
                bundleIdentifier: context.bundleId,
                maxDepth: maxDepth,
                maxNodes: maxNodes
            ) { winCtx in
                let selectors = GenericInputSelectors.selectors(for: context.bundleId)

                // Try all selectors in order (don't stop on first candidate failure)
                for selector in selectors {
                    guard let candidate = SelectorResolver.resolve(
                        selector: selector, in: winCtx.nodes, windowFrame: winCtx.frame
                    ) else { continue }

                    // Strategy 1: setValue (Native/Qt apps)
                    if AXActions.setValue(text, on: candidate.node.element) {
                        NSLog("[DraftPlacer] Placed via setValue in %@ (%d chars)",
                              context.bundleId, text.count)
                        placed = true
                        return
                    }

                    // Strategy 2: safePaste (Electron/browser apps)
                    // 4-stage safety verification:
                    //   1. Target app is frontmost
                    //   2. setFocused succeeds
                    //   3. System focused element PID matches target app
                    //   4. Focused element frame matches candidate frame (fail-closed)

                    guard let app = NSRunningApplication.runningApplications(
                        withBundleIdentifier: context.bundleId
                    ).first, app.isActive else { continue }

                    guard AXActions.setFocused(candidate.node.element) else { continue }
                    usleep(100_000)

                    guard let focused = AXQuery.systemFocusedElement(),
                          let focusedPid = AXQuery.pid(of: focused),
                          focusedPid == app.processIdentifier else { continue }

                    // Frame verification: fail-closed — if frames can't be read, abort
                    guard let candidateFrame = candidate.node.frame,
                          let focusedFrame = AXQuery.copyFrameAttribute(focused) else { continue }
                    let dx = abs(candidateFrame.midX - focusedFrame.midX)
                    let dy = abs(candidateFrame.midY - focusedFrame.midY)
                    guard dx < 50 && dy < 50 else { continue }

                    AXActions.safePaste(text)
                    NSLog("[DraftPlacer] Placed via safePaste in %@ (%d chars)",
                          context.bundleId, text.count)
                    placed = true
                    return
                }
            }
            return placed ? .placed : .fallback
        } catch let error as AXAppWindow.WindowError {
            switch error {
            case .appNotRunning:
                NSLog("[DraftPlacer] App not running: %@", context.bundleId)
                return .appNotRunning
            default:
                NSLog("[DraftPlacer] Window error: %@", String(describing: error))
                return .fallback
            }
        } catch {
            NSLog("[DraftPlacer] Unexpected error: %@", String(describing: error))
            return .fallback
        }
    }
}
