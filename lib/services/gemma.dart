import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:material_ui/material_ui.dart';

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
      // Con i prompt lunghi la mezza precisione può sbagliare le cifre.
      activationDataType: ActivationDataType.float32,
    );
  }

  /// Risposta libera del modello (per l'assistente "Chiedi"). Null se non
  /// risponde. Il modello resta caricato: chiamare [release] dopo.
  Future<String?> generate(AiModelOption m, String prompt, {int maxOutputTokens = 200}) async {
    working = true;
    notifyListeners();
    InferenceModelSession? session;
    try {
      final model = await _ensureModel(m);
      session = await model.createSession(temperature: 0, topK: 1, maxOutputTokens: maxOutputTokens);
      await session.addQueryChunk(Message.text(text: prompt, isUser: true));
      final out = await session.getResponse().timeout(const Duration(minutes: 2));
      error = null;
      return out;
    } catch (e) {
      error = '$e';
      return null;
    } finally {
      try {
        await session?.close();
      } catch (_) {}
      working = false;
      notifyListeners();
    }
  }

  /// Libera la memoria (il modello occupa qualche GB di RAM).
  Future<void> release() => _closeModel();

  Future<void> _closeModel() async {
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
  Future<String?> complete(String prompt) => ai.generate(model, prompt, maxOutputTokens: 200);
}
