import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/utils/http_service.dart' as http;

// FlyDesk: links this device to a support session opened from the CRM chat, so that nobody
// has to read or type an ID.
//
// The chat hands over a session token in one of two ways:
//   - Windows: the download is named `FlyDesk-s_<token>.exe`; the self-extracting launcher
//     passes its own file name to the app in the RUSTDESK_APPNAME environment variable;
//   - any desktop (app already installed): the link `flydesk://session/<token>`.
// The app then posts the token with its own ID to the CRM (`flydesk-api` built-in option, set
// at build time from FLYDESK_API). The support agent connects from the chat and the user
// accepts the request in the app (approve mode "click").

const String _kFlydeskApiOption = 'flydesk-api';
const String _kFlydeskAttachPath = '/api/public/flydesk/attach';
const int _kFlydeskMaxAttempts = 12;
const Duration _kFlydeskRetryDelay = Duration(seconds: 5);
// Attempts spent waiting for the ID server before the ID is sent anyway.
const int _kFlydeskReadyWaitAttempts = 4;

final RegExp _flydeskTokenInName =
    RegExp(r'-s_([0-9a-f]{32})(?![0-9a-f])', caseSensitive: false);
final RegExp _flydeskToken = RegExp(r'^[0-9a-f]{32}$', caseSensitive: false);

enum _FlydeskAttachResult { done, rejected, retry }

String? _flydeskPendingToken;
bool _flydeskAttaching = false;

/// Session token carried by a launcher file name such as `FlyDesk-s_<token>.exe`
/// (a browser may add ` (1)` before the extension).
String? flydeskTokenFromName(String? name) {
  if (name == null || name.isEmpty) return null;
  return _flydeskTokenInName.firstMatch(name)?.group(1)?.toLowerCase();
}

/// Session token of a `flydesk://session/<token>` link, null for any other link.
String? flydeskTokenFromUri(Uri uri) {
  if (uri.authority != 'session') return null;
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segments.length != 1 || !_flydeskToken.hasMatch(segments[0])) return null;
  return segments[0].toLowerCase();
}

/// True when [uri] is a session link (`<scheme>://session/...`). A well-formed one starts the
/// attach; a malformed one is dropped, never mistaken for a device to connect to.
bool flydeskHandleUri(Uri uri) {
  if (uri.authority != 'session') return false;
  final token = flydeskTokenFromUri(uri);
  if (token == null) {
    debugPrint('flydesk: malformed session link ignored');
    return true;
  }
  flydeskAttach(token);
  return true;
}

/// Called once when the desktop main window starts: picks up the token of the launcher name.
void flydeskInit() {
  if (!isDesktop) return;
  final token =
      flydeskTokenFromName(bind.mainGetEnv(key: kEnvPortableExecutable));
  if (token != null) flydeskAttach(token);
}

/// Posts this device's ID for [token]; retried while the ID or the network is not ready.
/// A newer token replaces one that is still being sent.
Future<void> flydeskAttach(String token) async {
  _flydeskPendingToken = token;
  if (_flydeskAttaching) return;
  _flydeskAttaching = true;
  try {
    var attempt = 0;
    while (attempt < _kFlydeskMaxAttempts) {
      final current = _flydeskPendingToken;
      if (current == null) break;
      final result = await _flydeskAttachOnce(current, attempt);
      if (_flydeskPendingToken != current) {
        // A newer link arrived meanwhile: start over with it.
        attempt = 0;
        continue;
      }
      if (result != _FlydeskAttachResult.retry) {
        _flydeskPendingToken = null;
        _flydeskNotify(result == _FlydeskAttachResult.done);
        break;
      }
      attempt++;
      if (attempt >= _kFlydeskMaxAttempts) {
        _flydeskPendingToken = null;
        _flydeskNotify(false);
        break;
      }
      await Future.delayed(_kFlydeskRetryDelay);
    }
  } finally {
    _flydeskAttaching = false;
  }
}

Future<_FlydeskAttachResult> _flydeskAttachOnce(String token, int attempt) async {
  final api = bind
      .mainGetBuildinOption(key: _kFlydeskApiOption)
      .trim()
      .replaceAll(RegExp(r'/+$'), '');
  if (api.isEmpty) {
    debugPrint('flydesk: no CRM address in this build');
    return _FlydeskAttachResult.rejected;
  }
  try {
    final id = (await bind.mainGetMyId()).trim();
    if (id.isEmpty) return _FlydeskAttachResult.retry;
    if (stateGlobal.svcStatus.value != SvcStatus.ready &&
        attempt < _kFlydeskReadyWaitAttempts) {
      return _FlydeskAttachResult.retry;
    }
    final resp = await http.post(Uri.parse('$api$_kFlydeskAttachPath'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'token': token,
          'id': id,
          'os': isWindows
              ? 'windows'
              : isMacOS
                  ? 'macos'
                  : 'linux',
          'version': await bind.mainGetVersion(),
        }));
    if (resp.statusCode == 200) return _FlydeskAttachResult.done;
    debugPrint('flydesk: attach answered HTTP ${resp.statusCode}');
    // 4xx: the session is unknown, ended or expired; trying again cannot help.
    if (resp.statusCode >= 400 && resp.statusCode < 500 && resp.statusCode != 429) {
      return _FlydeskAttachResult.rejected;
    }
    return _FlydeskAttachResult.retry;
  } catch (e) {
    debugPrint('flydesk: attach failed: $e');
    return _FlydeskAttachResult.retry;
  }
}

void _flydeskNotify(bool ok) {
  windowOnTop(null).catchError((Object e) {
    debugPrint('flydesk: windowOnTop failed: $e');
  });
  // Delayed so the overlay exists when the app was started by the link.
  Timer(const Duration(seconds: 1), () {
    showToast(
        translate(ok ? 'flydesk-session-ready' : 'flydesk-session-failed'),
        timeout: const Duration(seconds: 10));
  });
}
