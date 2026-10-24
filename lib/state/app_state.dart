import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import '../core/agent.dart';
import '../services/gemma.dart';
import '../services/native.dart';

enum Phase { idle, listening, thinking, speaking }

/// Stato dell'app: modello, permessi, conversazione, compito in corso.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  final AiAssistant ai = AiAssistant();
  final AndroidPhone phone = AndroidPhone();
  late final AndroidVoice voice = AndroidVoice(onListening: (l) {
    _setPhase(l ? Phase.listening : (busy ? Phase.thinking : Phase.idle));
  });

  NativeStatus status = NativeStatus.empty;
  final List<LogEntry> log = [];
  Phase phase = Phase.idle;
  bool busy = false;

  String modelId = aiModels.first.id;
  bool modelInstalled = false;

  Agent? _agent;
  Timer? _poll;
  File? _settingsFile;

  AiModelOption get model => aiModelById(modelId) ?? aiModels.first;

  bool get setupDone => modelInstalled && status.permissions && status.a11y;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    ai.addListener(notifyListeners);
    nativeChannel.setMethodCallHandler((call) async {
      if (call.method == 'wake') unawaited(activate(fromWake: true));
      return null;
    });
    await _loadSettings();
    await refreshStatus();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => refreshStatus());
    final w = await NativeControls.takeWake();
    if (w != null) unawaited(activate(fromWake: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) refreshStatus();
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
        modelId = (m['model'] as String?) ?? modelId;
        modelInstalled = m['installed'] == true;
      }
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _saveSettings() async {
    try {
      await _settingsFile?.writeAsString(jsonEncode({'model': modelId, 'installed': modelInstalled}));
    } catch (_) {}
  }

  // ---------- Modello ----------

  Future<void> installModel(AiModelOption m) async {
    try {
      await ai.install(m);
      modelId = m.id;
      modelInstalled = true;
      _agent = null;
      await _saveSettings();
    } catch (_) {
      // L'errore è in ai.error e viene mostrato.
    }
    notifyListeners();
  }

  Future<void> removeModel() async {
    await ai.uninstall(model);
    modelInstalled = false;
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
        brain: GemmaBrain(ai, model),
        ownPackage: status.package,
        onLog: _add,
      );

  /// "Ciao Dom", bolla o pulsante: ascolta un comando e lo esegue.
  Future<void> activate({bool fromWake = false}) async {
    if (busy) return;
    if (!modelInstalled) {
      await voice.say('Prima devo scaricare il modello: apri D. Dom Lab.');
      return;
    }
    busy = true;
    notifyListeners();
    await NativeControls.beginSession();
    try {
      HapticFeedback.mediumImpact();
      if (fromWake) await voice.say('Dimmi.');
      final text = await voice.listen();
      if (text == null || text.trim().isEmpty) {
        _add(const LogEntry('error', 'Non ho sentito niente.'));
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
    if (!modelInstalled) {
      _add(const LogEntry('error', 'Prima scarica il modello.'));
      return;
    }
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
