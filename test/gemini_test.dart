import 'dart:convert';
import 'dart:io';

import 'package:dom_lab/core/actions.dart';
import 'package:dom_lab/core/gemini_api.dart';
import 'package:dom_lab/services/gemini.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _ok(String text, {bool thought = false}) => jsonEncode({
      'candidates': [
        {
          'content': {
            'role': 'model',
            'parts': [
              if (thought) {'text': 'Sto ragionando...', 'thought': true},
              {'text': text},
            ]
          },
          'finishReason': 'STOP'
        }
      ]
    });

void main() {
  test('richiesta: JSON, temperatura 0, ragionamento minimo', () {
    final b = jsonDecode(geminiRequestBody(system: 'S', prompt: 'P', thinkingLevel: 'minimal')) as Map;
    expect(b['contents'][0]['parts'][0]['text'], 'P');
    expect(b['systemInstruction']['parts'][0]['text'], 'S');
    expect(b['generationConfig']['responseMimeType'], 'application/json');
    expect(b['generationConfig']['temperature'], 0);
    expect(b['generationConfig']['thinkingConfig']['thinkingLevel'], 'minimal');
    final b2 = jsonDecode(geminiRequestBody(system: 'S', prompt: 'P')) as Map;
    expect((b2['generationConfig'] as Map).containsKey('thinkingConfig'), isFalse);
  });

  test('risposta: salta il ragionamento, tiene il testo', () {
    expect(geminiText(_ok('{"action":"say","text":"ciao"}', thought: true)), '{"action":"say","text":"ciao"}');
    expect(geminiText('{"candidates":[]}'), isNull);
    expect(geminiText('non json'), isNull);
  });

  test('errori riconosciuti', () {
    expect(classifyGeminiError(400, '{"error":{"message":"API key not valid"}}'), GeminiFailure.badKey);
    expect(classifyGeminiError(403, ''), GeminiFailure.badKey);
    expect(classifyGeminiError(429, 'RESOURCE_EXHAUSTED'), GeminiFailure.quota);
    expect(classifyGeminiError(404, ''), GeminiFailure.notFound);
    expect(classifyGeminiError(503, ''), GeminiFailure.server);
    expect(hideKey('chiave AIzaXYZ errata', 'AIzaXYZ'), 'chiave *** errata');
  });

  test('risposta valida arriva all\'agente come azione', () async {
    late http.Request seen;
    final brain = GeminiBrain(
      key: 'AIzaTEST',
      model: geminiModels.first,
      client: MockClient((r) async {
        seen = r;
        return http.Response(_ok('{"action":"open_app","app":"Tuttosport"}'), 200);
      }),
    );
    final out = await brain.complete('prompt');
    expect(parseAction(out!)!.str('app'), 'Tuttosport');
    expect(seen.headers['x-goog-api-key'], 'AIzaTEST');
    expect(seen.url.toString(), contains('gemini-3.5-flash-lite:generateContent'));
    expect(seen.url.toString(), isNot(contains('AIzaTEST')));
  });

  test('limite gratuito finito: passa al modello di riserva', () async {
    final urls = <String>[];
    final brain = GeminiBrain(
      key: 'k',
      model: geminiModels.first,
      client: MockClient((r) async {
        urls.add(r.url.path);
        if (r.url.path.contains(geminiModels.first.id)) return http.Response('{"error":{"status":"RESOURCE_EXHAUSTED"}}', 429);
        return http.Response(_ok('{"action":"say","text":"ok"}'), 200);
      }),
    );
    expect(await brain.complete('p'), isNotNull);
    expect(brain.usedModel, geminiFallback.id);
    expect(urls, hasLength(2));
  });

  test('chiave sbagliata: messaggio chiaro, nessun altro tentativo', () async {
    var calls = 0;
    final brain = GeminiBrain(
      key: 'k',
      model: geminiModels.first,
      client: MockClient((r) async {
        calls++;
        return http.Response('{"error":{"message":"API key not valid. Please pass a valid API key."}}', 400);
      }),
    );
    expect(await brain.complete('p'), isNull);
    expect(brain.lastError, contains('chiave'));
    expect(calls, 1);
  });

  test('senza internet: lo dice e suggerisce i comandi rapidi', () async {
    final brain = GeminiBrain(
      key: 'k',
      model: geminiModels.first,
      client: MockClient((r) async => throw const SocketException('offline')),
    );
    expect(await brain.complete('p'), isNull);
    expect(brain.lastError, contains('comandi rapidi'));
  });

  test('senza chiave non chiama nessuno', () async {
    var calls = 0;
    final brain = GeminiBrain(key: '', model: geminiModels.first, client: MockClient((r) async {
      calls++;
      return http.Response('', 200);
    }));
    expect(await brain.complete('p'), isNull);
    expect(calls, 0);
  });
}
