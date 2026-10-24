import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../core/agent.dart';
import '../core/gemini_api.dart';
import '../services/gemini.dart';
import '../services/native.dart';

enum Phase { idle, listening, thinking, speaking }

/// Stato dell'app: chiave Gemini, permessi, conversazione, compito in corso.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final AndroidPhone phone = AndroidPhone();
  late final AndroidVoice voice = AndroidVoice(
    onListening: (l) => _setPhase(l ? Phase.listening : (busy ? Phase.thinking : Phase.idle)),
    onProblem: (m) => _add(LogEntry('error', m)),
  );

  NativeStatus status = NativeStatus.empty;
  final List<LogEntry> log = [];
  Phase phase = Phase.idle;
  bool busy = false;

  String modelId = geminiModels.first.id;
  String apiKey = '';

  /// Esito dell'ultima prova della chiave: null = mai provata, '' = ok.
  String? keyCheck;
  bool checkingKey = false;

  Agent? _agent;
  Timer? _poll;
  File? _settingsFile;

  GeminiModel get model => geminiById(modelId);

  bool get hasKey => apiKey.trim().isNotEmpty;

  bool get setupDone => hasKey && status.permissions && status.a11y;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    nativeChannel.setMethodCallHandler((call) async {
      if (call.method == 'wake') unawaited(activate(fromWake: true));
      return null;
    });
    await _loadSettings();
    await refreshStatus();
    _startPolling();
    final w = await NativeControls.takeWake();
    if (w != null) unawaited(activate(fromWake: true));
  }

  /// Aggiorna lo stato dei permessi solo con l'app aperta e solo finché
  /// serve (configurazione o download in corso): niente lavoro inutile.
  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      final busyNative = status.vosk.startsWith('downloading') || status.vosk == 'loading' || status.wakeStatus == 'loading';
      if (!setupDone || busyNative) refreshStatus();
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      refreshStatus();
      _startPolling();
    } else if (s == AppLifecycleState.paused) {
      _poll?.cancel();
      _poll = null;
    }
  }

  Future<void> refreshStatus() async {
    status = await NativeControls.status();
    notifyListeners();
  }

  // ---------- Impostazioni salvate ----------

  Future<void> _loadSettings() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _settingsFile = File('${dir.path}/dom_settings.json');
      if (await _settingsFile!.exists()) {
        final m = jsonDecode(await _settingsFile!.readAsString()) as Map<String, dynamic>;
        modelId = geminiById(m['gemini'] as String?).id;
        apiKey = (m['key'] as String?) ?? '';
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _saveSettings() async {
    try {
      await _settingsFile?.writeAsString(jsonEncode({'gemini': modelId, 'key': apiKey}));
    } catch (_) {}
  }

  // ---------- Gemini ----------

  /// Salva la chiave (resta solo sul telefono) e la prova.
  Future<void> setKey(String key) async {
    apiKey = key.trim();
    _agent = null;
    keyCheck = null;
    await _saveSettings();
    notifyListeners();
    if (hasKey) await testKey();
  }

  Future<void> testKey() async {
    checkingKey = true;
    notifyListeners();
    keyCheck = await GeminiBrain(key: apiKey, model: model).test() ?? '';
    checkingKey = false;
    notifyListeners();
  }

  Future<void> setModel(String id) async {
    modelId = geminiById(id).id;
    _agent = null;
    await _saveSettings();
    notifyListeners();
  }

  // ---------- Conversazione ----------

  void _setPhase(Phase p) {
    if (phase == p) return;
    phase = p;
    notifyListeners();
  }

  void _add(LogEntry e) {
    log.add(e);
    if (log.length > 200) log.removeRange(0, log.length - 200);
    if (e.kind == 'dom') _setPhase(Phase.speaking);
    notifyListeners();
  }

  Agent get agent => _agent ??= Agent(
        phone: phone,
        voice: voice,
        brain: GeminiBrain(key: apiKey, model: model),
        ownPackage: status.package,
        onLog: _add,
      );

  /// "Ciao Dom", bolla o pulsante: ascolta un comando e lo esegue.
  Future<void> activate({bool fromWake = false}) async {
    if (busy) return;
    busy = true;
    notifyListeners();
    await NativeControls.beginSession();
    try {
      unawaited(HapticFeedback.mediumImpact());
      if (fromWake) await voice.say('Dimmi.');
      final text = await voice.listen();
      if (text == null || text.trim().isEmpty) {
        if (log.isEmpty || log.last.kind != 'error') _add(const LogEntry('error', 'Non ho sentito niente.'));
        return;
      }
      await _run(text);
    } finally {
      busy = false;
      _setPhase(Phase.idle);
      await NativeControls.endSession();
      notifyListeners();
    }
  }

  /// Comando scritto a mano.
  Future<void> runTyped(String text) async {
    if (busy || text.trim().isEmpty) return;
    busy = true;
    notifyListeners();
    await NativeControls.beginSession();
    try {
      await _run(text.trim());
    } finally {
      busy = false;
      _setPhase(Phase.idle);
      await NativeControls.endSession();
      notifyListeners();
    }
  }

  Future<void> _run(String text) async {
    _setPhase(Phase.thinking);
    try {
      await agent.run(text);
    } catch (e) {
      _add(LogEntry('error', 'Errore: $e'));
      await voice.say('Si è verificato un errore.');
    }
  }

  void stop() {
    _agent?.stop();
    voice.stop();
  }

  void clearLog() {
    log.clear();
    notifyListeners();
  }

  // ---------- Interruttori ----------

  Future<void> setWake(bool on) async {
    if (on && !status.mic) await NativeControls.requestPermissions();
    await NativeControls.setWake(on);
    await refreshStatus();
  }

  Future<void> setBubble(bool on) async {
    await NativeControls.setBubble(on);
    await refreshStatus();
  }
}

/// Rende lo stato disponibile ai widget.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
}
