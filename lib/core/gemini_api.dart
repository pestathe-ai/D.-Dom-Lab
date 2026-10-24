import 'dart:convert';

/// Modelli Gemini gratuiti (ottobre 2026) usati da Dom.
class GeminiModel {
  const GeminiModel(this.id, this.label, this.description, this.thinking);

  final String id;
  final String label;
  final String description;

  /// Livello di ragionamento più basso supportato (più veloce).
  final String thinking;
}

const List<GeminiModel> geminiModels = [
  GeminiModel('gemini-3.5-flash-lite', 'Veloce', 'Gemini 3.5 Flash-Lite · il più rapido, più richieste gratis al giorno', 'minimal'),
  GeminiModel('gemini-3.8-flash', 'Sveglio', 'Gemini 3.8 Flash · capisce meglio i compiti lunghi, un po\' più lento', 'low'),
];

/// Modello di riserva se quello scelto ha finito le richieste gratuite.
const GeminiModel geminiFallback = GeminiModel('gemini-3.6-flash', 'Riserva', 'Gemini 3.6 Flash', 'minimal');

GeminiModel geminiById(String? id) {
  for (final m in [...geminiModels, geminiFallback]) {
    if (m.id == id) return m;
  }
  return geminiModels.first;
}

Uri geminiUrl(String model) =>
    Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent');

/// Corpo della richiesta: istruzioni, prompt, risposta JSON breve e
/// ragionamento al minimo (più veloce).
String geminiRequestBody({
  required String system,
  required String prompt,
  String? thinkingLevel,
  int maxOutputTokens = 1024,
}) {
  return jsonEncode({
    'systemInstruction': {
      'parts': [
        {'text': system}
      ]
    },
    'contents': [
      {
        'role': 'user',
        'parts': [
          {'text': prompt}
        ]
      }
    ],
    'generationConfig': {
      'temperature': 0,
      'maxOutputTokens': maxOutputTokens,
      'responseMimeType': 'application/json',
      if (thinkingLevel != null) 'thinkingConfig': {'thinkingLevel': thinkingLevel},
    },
  });
}

/// Testo della risposta (senza le parti di "ragionamento"). Null se vuota.
String? geminiText(String body) {
  try {
    final j = jsonDecode(body);
    final cands = (j is Map ? j['candidates'] : null) as List?;
    if (cands == null || cands.isEmpty) return null;
    final parts = ((cands.first as Map)['content'] as Map?)?['parts'] as List?;
    if (parts == null) return null;
    final b = StringBuffer();
    for (final p in parts) {
      if (p is Map && p['thought'] != true && p['text'] is String) b.write(p['text']);
    }
    final s = b.toString().trim();
    return s.isEmpty ? null : s;
  } catch (_) {
    return null;
  }
}

/// Tipo di errore, per decidere cosa fare.
enum GeminiFailure { badKey, quota, badRequest, notFound, server, network, empty }

GeminiFailure classifyGeminiError(int status, String body) {
  final b = body.toLowerCase();
  if (status == 400 && (b.contains('api key') || b.contains('api_key'))) return GeminiFailure.badKey;
  if (status == 401 || status == 403) return GeminiFailure.badKey;
  if (status == 429 || b.contains('resource_exhausted') || b.contains('quota')) return GeminiFailure.quota;
  if (status == 404) return GeminiFailure.notFound;
  if (status == 400) return GeminiFailure.badRequest;
  return GeminiFailure.server;
}

/// Messaggio da dire all'utente.
String geminiFailureMessage(GeminiFailure f) => switch (f) {
      GeminiFailure.badKey => 'La chiave di Gemini non è valida: controllala nelle impostazioni di Dom.',
      GeminiFailure.quota => 'Ho finito le richieste gratuite di Gemini per adesso. Riprova più tardi; i comandi rapidi funzionano lo stesso.',
      GeminiFailure.network => 'Non c\'è connessione a internet: posso fare solo i comandi rapidi, come chiama, apri, messaggi e sveglia.',
      GeminiFailure.notFound => 'Il modello di Gemini non è disponibile: scegline un altro nelle impostazioni.',
      GeminiFailure.badRequest => 'Gemini non ha accettato la richiesta.',
      GeminiFailure.server => 'Gemini non risponde in questo momento. Riprova tra poco.',
      GeminiFailure.empty => 'Gemini non ha dato una risposta.',
    };

/// Toglie la chiave da un testo (per non mostrarla negli errori).
String hideKey(String text, String key) => key.isEmpty ? text : text.replaceAll(key, '***');
