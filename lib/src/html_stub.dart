// A tiny stub so main.dart can compile on non-web platforms.
// When compiled for web, the real `dart:html` is used via conditional import.
class WindowStub {
  String? get localStorage => null;
  // We'll only use localStorage via top-level helpers; the stub just provides placeholders.
  // Nothing required here for web-only functionality.
}

// Export a getter named `window` so conditional import in main.dart can always access `window`.
final WindowStub window = WindowStub();
