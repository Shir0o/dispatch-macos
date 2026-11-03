# Contributing to DevTriage

Thank you for your interest in contributing to DevTriage! Our mission is to keep this application ultra-fast, minimal, and bloat-free for software developers on macOS.

---

## Architectural Invariants (Non-Negotiable)

To maintain code quality and performance, all contributions must uphold these core principles:

1. **Zero External Dependencies:**
   - The project relies strictly on first-party Apple frameworks (`Foundation`, `SwiftUI`, `AuthenticationServices`, `WebKit`, `Security`, `Network`). Do not introduce third-party package dependencies (e.g., Alamofire, SwiftyJSON).
2. **Sub-50ms Response & Minimal Footprint:**
   - Idle memory must remain below 50 MB RSS. Avoid unbounded collections, global singletons that hold memory indefinitely, or eager asset loading.
   - All list views must be virtualized and keyboard navigation must complete within a single frame budget (16ms).
3. **Safe Keyboard Triage:**
   - Fast triage actions (`e` for archive/dismiss) must **never** mutate public repository state on GitHub (e.g. closing an issue or PR). Local triage dismissal must remain strictly decoupled from repository mutations.
4. **Strict Security Isolation:**
   - `WKWebView` must keep `allowsContentJavaScript = false`. Remote image assets must not load automatically without explicit user authorization to prevent tracking beacons.
   - OAuth tokens must be stored exclusively in the macOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Never persist credentials to `UserDefaults` or plaintext caches.

---

## Development Workflow

### 1. Requirements
* macOS 14.0+
* Swift 6.0+ toolchain or Xcode 15+

### 2. Fast Static Verification
Before submitting a pull request, ensure your code compiles cleanly and passes all static checks:

```bash
# Build with Swift 6 strict concurrency checks
swift build

# Run targeted unit tests
swift test
```

### 3. Submitting Pull Requests
1. Fork the repository and create a descriptive branch: `feature/your-feature-name` or `fix/issue-description`.
2. Keep diffs surgical and focused directly on the issue being addressed.
3. Open a pull request against `main`. Ensure all GitHub Actions CI checks pass.
