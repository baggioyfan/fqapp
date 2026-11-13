/// Whether the app is running on a Linux desktop.
///
/// The definition lives in `desktop_platform.dart`, next to its Windows and
/// macOS siblings, because the three desktop ports share one window and
/// media-channel assembly there. This file stays as the import path the
/// page-level capability gates already use; it re-exports rather than
/// duplicating the `defaultTargetPlatform` check.
export 'desktop_platform.dart' show isLinuxDesktop;
