import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/http_service.dart' as http;
import 'package:get/get.dart';

// FlyDesk: a support session is opened, accepted, steered and ended from the CRM chat. The
// app shows no ID, no password and no approval window.
//
// The chat hands over a session token in one of two ways:
//   - Windows: the download is named `FlyDesk-s_<token>.exe`; the self-extracting launcher
//     passes its own file name to the app in the RUSTDESK_APPNAME environment variable;
//   - any desktop (app already installed): the link `flydesk://session/<token>`.
// Starting the app that way is the user's acceptance. The app then:
//   1. posts the token with its own ID and its one-time password to the CRM (`flydesk-api`
//      built-in option, set at build time from FLYDESK_API). Only the agent of that session
//      gets the password, so the agent's app opens the screen without any question here;
//   2. keeps the engine open for incoming connections (`flydesk-live`, a time limit written
//      again every few seconds) for as long as this window runs and the CRM says the session
//      is active. Without it the engine refuses every login and closes what is still open
//      (src/common.rs `flydesk_session_live`, src/server/connection.rs); the hidden connection
//      window does the same, sooner (models/server_model.dart);
//   3. follows the session in the CRM: the user's choice « control / view only » made in the
//      chat (written to the engine options before the engine is opened), and the end of the
//      session, whoever ends it;
//   4. sends the password again whenever the engine replaces it (it does as soon as it has let
//      somebody in).
// « Stop » in this window, or closing it, ends the session.

const String _kFlydeskApiOption = 'flydesk-api';
const String _kFlydeskAttachPath = '/api/public/flydesk/attach';
const String _kFlydeskStatePath = '/api/public/flydesk/state';
const String _kFlydeskEndPath = '/api/public/flydesk/end';
const int _kFlydeskMaxAttempts = 12;
const Duration _kFlydeskRetryDelay = Duration(seconds: 5);
// Attempts spent waiting for the ID server before the ID is sent anyway.
const int _kFlydeskReadyWaitAttempts = 4;

/// Engine option: time (ms since the epoch) until which incoming connections are allowed.
const String kFlydeskLiveOption = 'flydesk-live';
// How long one write of [kFlydeskLiveOption] keeps the engine open, and how often it is
// written again.
const int _kFlydeskLiveMs = 30 * 1000;
const int _kFlydeskLiveEveryMs = 10 * 1000;
// After the engine was closed it stays closed this long, so that the engine and the hidden
// connection window both see it and cut what was open.
const int _kFlydeskReopenGapMs = 4 * 1000;
// The CRM is asked about the session every so many ticks of one second.
const int _kFlydeskStateEveryTicks = 3;
// A CRM that gives no answer about the session for this long ends it on this computer.
const int _kFlydeskCrmSilenceMs = 60 * 1000;
const int _kFlydeskPasswordRetryTicks = 3;
// A longer pause between two ticks means the computer slept (or the timer was held back).
const int _kFlydeskTickGapMs = 15 * 1000;
const Duration _kFlydeskHttpTimeout = Duration(seconds: 10);

/// Engine options that « view only » switches off (and « control » gives back). The engine
/// reads them for a new connection; the hidden connection window applies them to open ones.
const List<String> kFlydeskControlOptions = [
  kOptionEnableKeyboard,
  kOptionEnableClipboard,
  kOptionEnableFileTransfer,
  kOptionEnableRemoteRestart,
];

final RegExp _flydeskTokenInName =
    RegExp(r'-s_([0-9a-f]{32})(?![0-9a-f])', caseSensitive: false);
final RegExp _flydeskToken = RegExp(r'^[0-9a-f]{32}$', caseSensitive: false);

enum _FlydeskAttachResult { done, rejected, retry }

/// What the window shows.
enum FlydeskPhase { idle, starting, active, ended, failed }

final Rx<FlydeskPhase> flydeskPhase = FlydeskPhase.idle.obs;

/// The user's choice in the chat: keyboard and mouse control (true) or view only.
final RxBool flydeskControl = true.obs;

/// A support agent is connected to this computer right now.
final RxBool flydeskConnected = false.obs;

String? _flydeskPendingToken;
bool _flydeskAttaching = false;
// The one-time password that went with the last successful attach.
String _flydeskAttachedPassword = '';

// The active session: its token, and the one-time password the CRM holds for it.
String? _flydeskSession;
String? _flydeskSentPassword;
bool _flydeskSendingPassword = false;
// Tick before which a refused or unanswered password is not sent again.
int _flydeskPasswordNextTick = 0;
// The CRM answered about the active session and the user's choice is in the engine options.
bool _flydeskStateKnown = false;
// Last answer of the CRM about the active session (ms since the epoch).
int _flydeskStateOkAt = 0;
// When [kFlydeskLiveOption] was last written for the active session (ms since the epoch).
int _flydeskLiveWrittenAt = 0;
// The engine is not opened before this time (ms since the epoch).
int _flydeskOpenNotBefore = 0;

Timer? _flydeskTimer;
int _flydeskTicks = 0;
bool _flydeskTicking = false;
bool _flydeskFollowing = false;
bool _flydeskOnline = false;
// Whether the engine options were put back to « no session » since this window started.
bool _flydeskReset = false;
// When the last tick ran (ms since the epoch).
int _flydeskLastTickAt = 0;
// The engine keeps HTTP answers by address: each request gets its own, so that two requests
// never read each other's answer (the server ignores the query).
int _flydeskRequestSeq = 0;

int _flydeskNow() => DateTime.now().millisecondsSinceEpoch;

/// True in a build made for a CRM (FLYDESK_API): sessions come from the chat only.
bool flydeskEnabled() => _flydeskApi().isNotEmpty;

String _flydeskApi() => bind
    .mainGetBuildinOption(key: _kFlydeskApiOption)
    .trim()
    .replaceAll(RegExp(r'/+$'), '');

/// The engine accepts incoming connections now, given the value of [kFlydeskLiveOption].
bool flydeskLive(String value) {
  final until = int.tryParse(value.trim());
  return until != null && until > DateTime.now().millisecondsSinceEpoch;
}

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

/// Called once when the desktop main window starts: starts following the engine and picks up
/// the token of the launcher name.
void flydeskInit() {
  if (!isDesktop) return;
  if (flydeskEnabled()) {
    _flydeskTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      _flydeskTick();
    });
  }
  final token =
      flydeskTokenFromName(bind.mainGetEnv(key: kEnvPortableExecutable));
  if (token != null) flydeskAttach(token);
}

/// Posts this device's ID and one-time password for [token]; retried while the ID or the
/// network is not ready. A newer token replaces one that is still being sent.
Future<void> flydeskAttach(String token) async {
  _flydeskPendingToken = token;
  if (_flydeskAttaching) return;
  _flydeskAttaching = true;
  if (_flydeskSession == null) flydeskPhase.value = FlydeskPhase.starting;
  // Delayed: an app started by the link hides its window while it starts.
  Timer(const Duration(seconds: 1), _flydeskShowWindow);
  try {
    var attempt = 0;
    while (attempt < _kFlydeskMaxAttempts) {
      final current = _flydeskPendingToken;
      if (current == null) break;
      final result = await _flydeskAttachOnce(current, attempt);
      if (_flydeskPendingToken != current) {
        // A newer link arrived meanwhile, or the user pressed Stop: start over or give up.
        attempt = 0;
        continue;
      }
      if (result != _FlydeskAttachResult.retry) {
        _flydeskPendingToken = null;
        if (result == _FlydeskAttachResult.done) {
          await _flydeskStarted(current);
        } else if (_flydeskSession == null) {
          flydeskPhase.value = FlydeskPhase.failed;
        }
        _flydeskNotify(result == _FlydeskAttachResult.done);
        break;
      }
      attempt++;
      if (attempt >= _kFlydeskMaxAttempts) {
        _flydeskPendingToken = null;
        if (_flydeskSession == null) flydeskPhase.value = FlydeskPhase.failed;
        _flydeskNotify(false);
        break;
      }
      await Future.delayed(_kFlydeskRetryDelay);
    }
  } finally {
    _flydeskAttaching = false;
    if (_flydeskSession == null && flydeskPhase.value == FlydeskPhase.starting) {
      flydeskPhase.value = FlydeskPhase.idle;
    }
  }
}

/// A session is active or being started.
bool flydeskSessionOpen() =>
    _flydeskSession != null || _flydeskPendingToken != null;

/// The user's « Stop »: nobody can connect any more from this instant, even when the CRM
/// cannot be told right now.
Future<void> flydeskStop() async {
  // The active session, or the one that was still being started.
  final token = _flydeskSession ?? _flydeskPendingToken;
  _flydeskPendingToken = null;
  if (token == null) return;
  await _flydeskFinish(FlydeskPhase.ended);
  await _flydeskTellEnd(token);
}

/// The main window is being closed: a session never goes on behind a window the user closed.
/// Awaited by the close handler, because closing the last window ends the app.
Future<void> flydeskOnMainWindowClosed() async {
  if (!flydeskSessionOpen()) return;
  try {
    await flydeskStop().timeout(const Duration(seconds: 5));
  } catch (e) {
    debugPrint('flydesk: stopping at window close: $e');
  }
}

// Tells the CRM that the session of [token] is over, so both chat cards follow.
Future<void> _flydeskTellEnd(String token) async {
  for (var i = 0; i < 3; i++) {
    final status = await _flydeskPostStatus(_kFlydeskEndPath, {'token': token});
    // Answered (ended now, or already ended): done. No answer or a busy server: once more.
    if (status != null && status < 500 && status != 429) return;
    await Future.delayed(const Duration(seconds: 2));
  }
  debugPrint('flydesk: the CRM could not be told that the session was stopped');
}

Future<_FlydeskAttachResult> _flydeskAttachOnce(String token, int attempt) async {
  if (_flydeskApi().isEmpty) {
    debugPrint('flydesk: no CRM address in this build');
    return _FlydeskAttachResult.rejected;
  }
  try {
    final id = (await bind.mainGetMyId()).trim();
    if (id.isEmpty) return _FlydeskAttachResult.retry;
    final password = await bind.mainGetTemporaryPassword();
    final waiting = !_flydeskOnline || password.isEmpty;
    if (waiting && attempt < _kFlydeskReadyWaitAttempts) {
      return _FlydeskAttachResult.retry;
    }
    final status = await _flydeskPostAttach(token, id, password);
    if (status == 200) {
      _flydeskAttachedPassword = password;
      return _FlydeskAttachResult.done;
    }
    debugPrint('flydesk: attach answered HTTP $status');
    // 4xx: the session is unknown, ended or expired; trying again cannot help.
    if (status != null && status >= 400 && status < 500 && status != 429) {
      return _FlydeskAttachResult.rejected;
    }
    return _FlydeskAttachResult.retry;
  } catch (e) {
    debugPrint('flydesk: attach failed: $e');
    return _FlydeskAttachResult.retry;
  }
}

Future<int?> _flydeskPostAttach(String token, String id, String password) async {
  return _flydeskPostStatus(_kFlydeskAttachPath, {
    'token': token,
    'id': id,
    'os': isWindows
        ? 'windows'
        : isMacOS
            ? 'macos'
            : 'linux',
    'version': await bind.mainGetVersion(),
    if (password.isNotEmpty) 'password': password,
  });
}

/// HTTP status of a POST to the CRM, null when there was no answer.
Future<int?> _flydeskPostStatus(String path, Map<String, dynamic> body) async {
  return (await _flydeskPost(path, body))?.statusCode;
}

Future<http.Response?> _flydeskPost(
    String path, Map<String, dynamic> body) async {
  final api = _flydeskApi();
  if (api.isEmpty) return null;
  _flydeskRequestSeq = (_flydeskRequestSeq + 1) % 256;
  final seq = _flydeskRequestSeq;
  try {
    return await http
        .post(Uri.parse('$api$path?r=$seq'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body))
        .timeout(_kFlydeskHttpTimeout);
  } catch (e) {
    debugPrint('flydesk: $path failed: $e');
    return null;
  }
}

// The CRM linked this device to the session of [token]: it becomes the active one. The engine
// is opened by the tick, once the CRM has told the user's choice for this session.
Future<void> _flydeskStarted(String token) async {
  final previous = _flydeskSession;
  _flydeskSession = token;
  _flydeskSentPassword =
      _flydeskAttachedPassword.isEmpty ? null : _flydeskAttachedPassword;
  _flydeskPasswordNextTick = 0;
  _flydeskStateKnown = false;
  _flydeskStateOkAt = _flydeskNow();
  _flydeskLiveWrittenAt = 0;
  if (previous != null && previous != token) {
    // One session at a time. The previous one ends here and in the CRM: its open connections
    // are cut and the password its agent could get stops working. The new session gets the
    // new password from the tick.
    flydeskPhase.value = FlydeskPhase.starting;
    await _flydeskCloseEngine();
    _flydeskSentPassword = null;
    unawaited(_flydeskTellEnd(previous));
    if (_flydeskSession != token) return;
  }
  await _flydeskPollState(token);
}

// The session is over on this computer.
Future<void> _flydeskFinish(FlydeskPhase phase) async {
  _flydeskSession = null;
  _flydeskSentPassword = null;
  _flydeskStateKnown = false;
  flydeskPhase.value = phase;
  flydeskControl.value = true;
  await _flydeskCloseEngine();
}

// The engine refuses every login and cuts what is open (the hidden connection window does it
// first), and the password the CRM knows stops working.
Future<void> _flydeskCloseEngine() async {
  _flydeskOpenNotBefore = _flydeskNow() + _kFlydeskReopenGapMs;
  try {
    if (await bind.optionSynced()) {
      await _flydeskSetLive(false);
      await _flydeskWriteControl(true);
    } else {
      // Not possible now: done by the next tick.
      _flydeskReset = false;
    }
    bind.mainUpdateTemporaryPassword();
  } catch (e) {
    debugPrint('flydesk: closing the engine failed: $e');
    _flydeskReset = false;
  }
}

Future<void> _flydeskSetLive(bool live) async {
  final now = _flydeskNow();
  await bind.mainSetOption(
      key: kFlydeskLiveOption,
      value: live ? (now + _kFlydeskLiveMs).toString() : '');
  _flydeskLiveWrittenAt = live ? now : 0;
  // The session ended while this was being written: closed stays the last word.
  if (live && _flydeskSession == null) {
    await bind.mainSetOption(key: kFlydeskLiveOption, value: '');
    _flydeskLiveWrittenAt = 0;
  }
}

// « Control » removes the restrictions, « view only » sets them.
Future<void> _flydeskWriteControl(bool control) async {
  final wanted = control ? '' : 'N';
  for (final key in kFlydeskControlOptions) {
    if (await bind.mainGetOption(key: key) != wanted) {
      await bind.mainSetOption(key: key, value: wanted);
    }
  }
}

// Once a second, local work only (the requests to the CRM run beside it, so a slow answer
// never delays the time limit): what the engine says, and the engine kept open or closed.
Future<void> _flydeskTick() async {
  if (_flydeskTicking) return;
  _flydeskTicking = true;
  try {
    _flydeskTicks++;
    final now = _flydeskNow();
    final paused =
        _flydeskLastTickAt != 0 && now - _flydeskLastTickAt > _kFlydeskTickGapMs;
    _flydeskLastTickAt = now;
    try {
      final status =
          jsonDecode(await bind.mainGetConnectStatus()) as Map<String, dynamic>;
      _flydeskOnline = status['status_num'] == 1;
      final count = status['video_conn_count'];
      flydeskConnected.value = count is int && count > 0;
    } catch (e) {
      debugPrint('flydesk: engine status unavailable: $e');
    }
    // Engine options may only be written once they were read from the engine: a write sends
    // the whole set back.
    if (!await bind.optionSynced()) return;
    final token = _flydeskSession;
    if (token == null) {
      if (!_flydeskReset) {
        // Left behind by a window that was closed or killed during a session.
        _flydeskReset = true;
        await _flydeskSetLive(false);
        await _flydeskWriteControl(true);
        // A window killed during a session left its one-time password in use.
        bind.mainUpdateTemporaryPassword();
      } else if ((await bind.mainGetOption(key: kFlydeskLiveOption))
          .isNotEmpty) {
        // Put back by an option write that crossed the closing one.
        await _flydeskSetLive(false);
      }
      return;
    }
    _flydeskReset = false;
    if (paused) {
      // The silence was this computer's, not the CRM's: ask again first. The engine is not
      // kept open until the answer.
      _flydeskStateKnown = false;
      _flydeskStateOkAt = now;
    }
    if (now - _flydeskStateOkAt >= _kFlydeskCrmSilenceMs) {
      debugPrint('flydesk: no answer from the CRM, session closed');
      await _flydeskFinish(FlydeskPhase.ended);
      // A few tries in case it answers again, so the chat cards do not stay on « ready ».
      unawaited(_flydeskTellEnd(token));
      return;
    }
    if (_flydeskStateKnown &&
        now >= _flydeskOpenNotBefore &&
        now - _flydeskLiveWrittenAt >= _kFlydeskLiveEveryMs) {
      await _flydeskSetLive(true);
      if (_flydeskSession == token) flydeskPhase.value = FlydeskPhase.active;
    }
    if (!_flydeskFollowing) unawaited(_flydeskFollow(token));
  } catch (e) {
    debugPrint('flydesk: tick failed: $e');
  } finally {
    _flydeskTicking = false;
  }
}

// The requests to the CRM for the active session, one round at a time.
Future<void> _flydeskFollow(String token) async {
  _flydeskFollowing = true;
  try {
    if (!_flydeskStateKnown || _flydeskTicks % _kFlydeskStateEveryTicks == 0) {
      await _flydeskPollState(token);
      if (_flydeskSession != token) return;
    }
    await _flydeskSendPassword(token);
  } catch (e) {
    debugPrint('flydesk: following the session failed: $e');
  } finally {
    _flydeskFollowing = false;
  }
}

// Asks the CRM about the session. « Not found » is the end of the session, whoever ended it.
Future<void> _flydeskPollState(String token) async {
  final resp = await _flydeskPost(_kFlydeskStatePath, {'token': token});
  if (_flydeskSession != token) return;
  final status = resp?.statusCode;
  // No answer or a busy server: the tick ends the session when this lasts.
  if (resp == null || status == null || status >= 500 || status == 429) return;
  if (status != 200) {
    await _flydeskFinish(FlydeskPhase.ended);
    return;
  }
  var control = true;
  try {
    final data = (jsonDecode(resp.body) as Map<String, dynamic>)['data'];
    if (data is Map && data['control'] == false) control = false;
  } catch (e) {
    debugPrint('flydesk: unreadable state answer: $e');
    return;
  }
  _flydeskStateOkAt = _flydeskNow();
  flydeskControl.value = control;
  if (!await bind.optionSynced()) return;
  await _flydeskWriteControl(control);
  // Only now may the engine be opened for this session.
  if (_flydeskSession == token) _flydeskStateKnown = true;
}

// The engine replaced its one-time password: the CRM gets the new one for the same session.
Future<void> _flydeskSendPassword(String token) async {
  if (_flydeskSendingPassword || _flydeskAttaching) return;
  final password = await bind.mainGetTemporaryPassword();
  if (password.isEmpty || password == _flydeskSentPassword) return;
  if (_flydeskTicks < _flydeskPasswordNextTick) return;
  _flydeskSendingPassword = true;
  try {
    final id = (await bind.mainGetMyId()).trim();
    if (id.isEmpty) return;
    final status = await _flydeskPostAttach(token, id, password);
    if (_flydeskSession != token) return;
    if (status == 200) {
      _flydeskSentPassword = password;
      _flydeskPasswordNextTick = 0;
    } else if (status != null && status >= 400 && status < 500 && status != 429) {
      await _flydeskFinish(FlydeskPhase.ended);
    } else {
      _flydeskPasswordNextTick = _flydeskTicks + _kFlydeskPasswordRetryTicks;
    }
  } finally {
    _flydeskSendingPassword = false;
  }
}

void _flydeskShowWindow() {
  windowOnTop(null).catchError((Object e) {
    debugPrint('flydesk: windowOnTop failed: $e');
  });
}

void _flydeskNotify(bool ok) {
  _flydeskShowWindow();
  if (ok) return;
  // Delayed so the overlay exists when the app was started by the link.
  Timer(const Duration(seconds: 1), () {
    showToast(translate('flydesk-session-failed'),
        timeout: const Duration(seconds: 10));
  });
}
