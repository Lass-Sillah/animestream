import 'dart:io';

/// Platform groupings used across the app.
/// Use these for layout/UX decisions; keep Platform.isAndroid for android-only apis (better_player, storage perms, tv).
class AppPlatform {
  /// Desktop OS (windows, linux, macos)
  static final bool isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// Mobile OS (android, ios)
  static final bool isMobile = Platform.isAndroid || Platform.isIOS;

  /// Apple OS (macos, ios). No self updater & sandboxed file access on these.
  static final bool isApple = Platform.isMacOS || Platform.isIOS;
}
