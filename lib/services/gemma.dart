import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:material_ui/material_ui.dart';

import '../core/actions.dart' show parseAction;
import '../core/agent.dart' show Brain;

/// Un modello linguistico scaricabile sul telefono.
class AiModelOption {
  const AiModelOption({
    required this.id,
    required this.label,
    required this.description,
    required this.url,
    required this.type,
  });

  final String id;
  final String label;
  final String description;
  final String url;
  final ModelType type;

  /// Nome del file scaricato (è anche l'id del modello installato).
  String get fileName => Uri.parse(url).pathSegments.last;
}

const List<AiModelOption> aiModels = [
  AiModelOption(
    id: 'gemma4-e2b',
    label: 'Gemma 4 E2B (Google)',
    description: 'Consigliato · 2,6 GB · capisce bene l\'italiano',
    url: 'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
    type: ModelType.gemma4,
  ),
  AiModelOption(
    id: 'qwen25-1.5b',
    label: 'Qwen 2.5 1.5B',
    description: 'Più leggero · 1,6 GB · meno preciso',
    url: 'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm',
    type: ModelType.qwen,
  ),
];

AiModelOption? aiModelById(String? id) {
  for (final m in aiModels) {
    if (m.id == id) return m;
  }
  return null;
}

/// Modello linguistico che gira tutto sul telefono (LiteRT-LM, sulla GPU):
/// niente esce dal dispositivo. (Stesso motore di D. Paper Lab.)
class AiAssistant extends ChangeNotifier {
  bool _initialized = false;
  AiModelOption? _active;
  InferenceModel? _model;
  CancelToken? _cancel;

  /// Percentuale di download in corso, o null.
  int? progress;
  String? error;
  bool working = false;

  bool get downloading => progress != null;

  Future<void> _init() async {
    if (_initialized) return;
    await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);
    _initialized = true;
  }

  /// Scarica (la prima volta) e attiva il modello. Se il file c'è già, non
  /// lo riscarica.
  Future<void> install(AiModelOption m, {bool quiet = false}) async {
    if (downloading) return;
    error = null;
    if (!quiet) {
      progress = 0;
      notifyListeners();
    }
    _cancel = CancelToken();
    try {
      await _init();
      await _closeModel();
      await FlutterEdgeAi.installModel(modelType: m.type, fileType: ModelFileType.litertlm)
          .fromNetwork(m.url)
          .withCancelToken(_cancel!)
          .withProgress((p) {
            if (quiet) return;
            progress = p;
            notifyListeners();
          })
          .install();
      _active = m;
    } catch (e) {
      _active = null;
      error = e is DownloadCancelledException ? 'Download annullato' : '$e';
      rethrow;
    } finally {
      progress = null;
      _cancel = null;
      notifyListeners();
    }
  }

  void cancelDownload() => _cancel?.cancel('Annullato');

  /// Cancella il modello dal telefono.
  Future<void> uninstall(AiModelOption m) async {
    await _init();
    await _closeModel();
    try {
      await FlutterEdgeAi.uninstallModel(m.fileName);
    } catch (_) {
      // Già cancellato.
    }
    if (_active?.id == m.id) _active = null;
    notifyListeners();
  }

  Future<InferenceModel> _ensureModel(AiModelOption m) async {
    if (_active?.id != m.id || !FlutterEdgeAi.hasActiveModel()) {
      await install(m, quiet: true);
    }
    return _model ??= await FlutterEdgeAi.getActiveModel(
      maxTokens: 4096,
      preferredBackend: PreferredBackend.gpu,
    );
  }

  /// Una richiesta alla volta: il motore non lavora in parallelo.
  Future<void> _queue = Future<void>.value();

  Future<T> _locked<T>(Future<T> Function() f) {
    final next = _queue.then((_) => f());
    _queue = next.then((_) {}, onError: (_) {});
    return next;
  }

  bool get ready => _model != null;

  /// Carica il modello sulla GPU e fa una prova a vuoto, così il primo
  /// comando vero non aspetta il caricamento.
  Future<void> warmUp(AiModelOption m) => _locked(() async {
        if (_model != null && _active?.id == m.id) return;
        InferenceModelSession? session;
        try {
          final model = await _ensureModel(m);
          session = await model.createSession(temperature: 0, topK: 1, maxOutputTokens: 4);
          await session.addQueryChunk(Message.text(text: 'Rispondi solo: ok', isUser: true));
          await session.getResponse().timeout(const Duration(minutes: 2));
        } catch (e) {
          error = '$e';
        } finally {
          try {
            await session?.close();
          } catch (_) {}
          notifyListeners();
        }
      });

  InferenceModelSession? _task;
  int _taskChars = 0;

  /// Passo di un compito. Riusa la sessione del compito (il modello non
  /// rilegge tutto ogni volta): manda solo [delta] se c'è ancora spazio,
  /// altrimenti riparte da [full]. Si ferma appena [done] dice che la
  /// risposta è completa.
  Future<String?> step(AiModelOption m, {required String full, String? delta, bool Function(String)? done}) =>
      _locked(() async {
        working = true;
        notifyListeners();
        try {
          final model = await _ensureModel(m);
          String chunk;
          if (_task != null && delta != null && _taskChars + delta.length < 8500) {
            chunk = delta;
          } else {
            await _closeTask();
            _task = await model.createSession(temperature: 0, topK: 1, maxOutputTokens: 160);
            _taskChars = 0;
            chunk = full;
          }
          final session = _task!;
          await session.addQueryChunk(Message.text(text: chunk, isUser: true));
          final b = StringBuffer();
          final sub = session.getResponseAsync();
          await for (final t in sub.timeout(const Duration(seconds: 90))) {
            b.write(t);
            if (done != null && done(b.toString())) {
              try {
                await session.stopGeneration();
              } catch (_) {}
              break;
            }
          }
          _taskChars += chunk.length + b.length;
          error = null;
          return b.toString();
        } catch (e) {
          error = '$e';
          await _closeTask();
          return null;
        } finally {
          working = false;
          notifyListeners();
        }
      });

  /// Fine del compito: chiude la sessione (il modello resta caricato).
  Future<void> endTask() => _locked(_closeTask);

  Future<void> _closeTask() async {
    final t = _task;
    _task = null;
    _taskChars = 0;
    if (t != null) {
      try {
        await t.close();
      } catch (_) {}
    }
  }

  /// Libera la memoria (il modello occupa qualche GB di RAM).
  Future<void> release() => _closeModel();

  Future<void> _closeModel() async {
    await _closeTask();
    final m = _model;
    _model = null;
    if (m != null) {
      try {
        await m.close();
      } catch (_) {}
    }
  }
}

/// Il "cervello" dell'agente: il modello scelto, sul telefono.
class GemmaBrain implements Brain {
  GemmaBrain(this.ai, this.model);

  final AiAssistant ai;
  final AiModelOption model;

  @override
  Future<String?> complete(String prompt, {String? delta}) =>
      ai.step(model, full: prompt, delta: delta, done: (s) => parseAction(s) != null);

  @override
  Future<void> reset() => ai.endTask();
}
