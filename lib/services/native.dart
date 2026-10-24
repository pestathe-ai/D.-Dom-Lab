import 'package:flutter/services.dart';

import '../core/agent.dart';
import '../core/apps.dart';
import '../core/contacts.dart';
import '../core/screen.dart';

/// Canale verso il codice Android (MainActivity.kt).
const MethodChannel nativeChannel = MethodChannel('domlab/native');

Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
  try {
    return await nativeChannel.invokeMethod<T>(method, args);
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

Future<bool> _ok(String method, [Map<String, Object?>? args]) async => await _call<bool>(method, args) ?? false;

/// Il telefono vero, comandato dal servizio di accessibilità e dagli intent.
class AndroidPhone implements Phone {
  @override
  Future<ScreenState> screen() async {
    final m = await _call<Map<dynamic, dynamic>>('screen');
    return m == null ? ScreenState.empty : ScreenState.fromMap(m);
  }

  @override
  Future<List<InstalledApp>> apps() async {
    final l = await _call<List<dynamic>>('apps') ?? const [];
    return [for (final m in l) if (m is Map) InstalledApp.fromMap(m)];
  }

  @override
  Future<bool> openApp(String package) => _ok('openApp', {'package': package});

  @override
  Future<bool> tap(int id) => _ok('tap', {'id': id});

  @override
  Future<bool> typeText(int id, String text) => _ok('type', {'id': id, 'text': text});

  @override
  Future<bool> scroll(String direction) => _ok('scroll', {'direction': direction});

  @override
  Future<bool> globalAction(String action) => _ok('global', {'action': action});

  @override
  Future<List<Contact>> findContacts(String query) async {
    final l = await _call<List<dynamic>>('contacts', {'query': query}) ?? const [];
    return [for (final m in l) if (m is Map) Contact.fromMap(m)];
  }

  @override
  Future<bool> call(String number) => _ok('call', {'number': number});

  @override
  Future<bool> sendSms(String number, String text) => _ok('sms', {'number': number, 'text': text});

  @override
  Future<bool> openWhatsApp(String phone, String text) => _ok('whatsapp', {'phone': phone, 'text': text});

  @override
  Future<bool> composeEmail(String to, String subject, String body) =>
      _ok('email', {'to': to, 'subject': subject, 'body': body});

  @override
  Future<bool> setAlarm(int hour, int minute, String label) =>
      _ok('alarm', {'hour': hour, 'minute': minute, 'label': label});

  @override
  Future<bool> setTimer(int seconds, String label) => _ok('timer', {'seconds': seconds, 'label': label});

  @override
  Future<bool> openUrl(String url) => _ok('openUrl', {'url': url});

  @override
  Future<bool> openSettings(String panel) => _ok('settings', {'panel': panel});

  @override
  Future<void> pause(Duration d) => Future<void>.delayed(d);
}

/// Voce di sistema: sintesi vocale e riconoscimento in italiano.
class AndroidVoice implements Voice {
  AndroidVoice({this.onListening, this.onProblem});

  /// Avvisa l'interfaccia quando il microfono è aperto.
  final void Function(bool listening)? onListening;

  /// Problemi del riconoscimento vocale, da mostrare all'utente.
  final void Function(String message)? onProblem;

  /// Motore che ha capito l'ultimo comando (system, google, vosk...).
  String lastEngine = '';

  @override
  Future<void> say(String text) async {
    await _call<bool>('speak', {'text': text});
  }

  @override
  Future<String?> listen() async {
    onListening?.call(true);
    try {
      final r = await _call<Map<dynamic, dynamic>>('listen', {'timeoutMs': 7000});
      if (r == null) {
        onProblem?.call('Riconoscimento vocale non disponibile.');
        return null;
      }
      lastEngine = (r['engine'] ?? '').toString();
      final err = r['error']?.toString();
      final text = r['text']?.toString();
      if (err != null && err.isNotEmpty && err != 'annullato' && (text == null || text.isEmpty)) {
        onProblem?.call('Microfono: $err');
      }
      return text;
    } finally {
      onListening?.call(false);
    }
  }

  Future<void> stop() async {
    await _call<bool>('stopSpeaking');
    await _call<bool>('stopListening');
  }
}

/// Stato dei permessi e dei servizi.
class NativeStatus {
  const NativeStatus(this._m);

  final Map<dynamic, dynamic> _m;

  static const empty = NativeStatus({});

  bool _b(String k) => _m[k] == true;
  bool get a11y => _b('a11y');
  bool get mic => _b('mic');
  bool get contacts => _b('contacts');
  bool get phone => _b('phone');
  bool get sms => _b('sms');
  bool get battery => _b('battery');
  bool get wake => _b('wake');
  bool get recognizer => _b('recognizer');
  String get engine => (_m['engine'] ?? '').toString();
  String get lastHeard => (_m['lastHeard'] ?? '').toString();

  /// Voce offline (Vosk): missing, downloaded, downloading N, loading, ready, error ...
  String get vosk => (_m['vosk'] ?? 'missing').toString();
  bool get voskReady => vosk == 'ready' || vosk == 'downloaded' || vosk == 'loading';
  bool get bubble => _b('bubble');
  String get wakeStatus => (_m['wakeStatus'] ?? 'off').toString();
  String get package => (_m['package'] ?? '').toString();
  bool get permissions => mic && contacts && phone && sms;
}

class NativeControls {
  static Future<NativeStatus> status() async {
    final m = await _call<Map<dynamic, dynamic>>('status');
    return m == null ? NativeStatus.empty : NativeStatus(m);
  }

  static Future<bool> requestPermissions() => _ok('requestPermissions');
  static Future<bool> openA11ySettings() => _ok('openA11ySettings');
  static Future<bool> openBatterySettings() => _ok('openBatterySettings');
  static Future<bool> openAppSettings() => _ok('openAppSettings');
  static Future<bool> setWake(bool on) => _ok('setWake', {'on': on});
  static Future<bool> downloadVosk() => _ok('downloadVosk');
  static Future<bool> setBubble(bool on) => _ok('setBubble', {'on': on});
  static Future<bool> beginSession() => _ok('beginSession');
  static Future<bool> endSession() => _ok('endSession');
  static Future<String?> takeWake() => _call<String>('takeWake');
}
