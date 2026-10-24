import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/agent.dart' show Brain;
import '../core/gemini_api.dart';

/// Il "cervello" di Dom: Gemini via internet (piano gratuito). Al telefono
/// non costa niente: niente modelli in memoria, niente calcoli.
class GeminiBrain implements Brain {
  GeminiBrain({required this.key, required this.model, http.Client? client}) : _client = client ?? http.Client();

  final String key;
  final GeminiModel model;
  final http.Client _client;

  /// Modello che ha risposto l'ultima volta (può essere la riserva).
  String usedModel = '';

  @override
  String? lastError;

  /// Se il server rifiuta l'impostazione del ragionamento, la togliamo.
  static bool _noThinkingConfig = false;

  @override
  Future<String?> complete(String prompt, {String? delta}) async {
    lastError = null;
    if (key.trim().isEmpty) {
      lastError = geminiFailureMessage(GeminiFailure.badKey);
      return null;
    }
    final order = [model, if (model.id != geminiFallback.id) geminiFallback];
    GeminiFailure? last;
    for (final m in order) {
      final r = await _call(m, prompt);
      if (r.$1 != null) {
        usedModel = m.id;
        return r.$1;
      }
      last = r.$2;
      // Con la chiave sbagliata o senza rete, inutile provare un altro modello.
      if (last == GeminiFailure.badKey || last == GeminiFailure.network) break;
    }
    lastError = geminiFailureMessage(last ?? GeminiFailure.empty);
    return null;
  }

  Future<(String?, GeminiFailure?)> _call(GeminiModel m, String prompt) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final body = geminiRequestBody(
        system: 'Sei Dom. Rispondi solo con un oggetto JSON valido.',
        prompt: prompt,
        thinkingLevel: _noThinkingConfig ? null : m.thinking,
      );
      http.Response res;
      try {
        res = await _client
            .post(geminiUrl(m.id), headers: {'Content-Type': 'application/json', 'x-goog-api-key': key.trim()}, body: body)
            .timeout(const Duration(seconds: 25));
      } on SocketException {
        return (null, GeminiFailure.network);
      } on TimeoutException {
        if (attempt == 0) continue;
        return (null, GeminiFailure.server);
      } on http.ClientException {
        return (null, GeminiFailure.network);
      }
      if (res.statusCode == 200) {
        final t = geminiText(res.body);
        return t == null ? (null, GeminiFailure.empty) : (t, null);
      }
      final f = classifyGeminiError(res.statusCode, res.body);
      if (f == GeminiFailure.badRequest && !_noThinkingConfig && res.body.toLowerCase().contains('thinking')) {
        _noThinkingConfig = true;
        continue;
      }
      if (f == GeminiFailure.server && attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        continue;
      }
      return (null, f);
    }
    return (null, GeminiFailure.server);
  }

  @override
  Future<void> reset() async {}

  /// Prova la chiave con una richiesta minima. Null se va tutto bene,
  /// altrimenti il messaggio d'errore.
  Future<String?> test() async {
    final r = await complete('Rispondi con {"action":"say","text":"ok"}');
    return r == null ? lastError : null;
  }
}
