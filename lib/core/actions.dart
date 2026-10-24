import 'dart:convert';

/// Un'azione decisa dal modello: un nome e i suoi parametri.
class AgentAction {
  const AgentAction(this.name, [this.args = const {}]);

  final String name;
  final Map<String, dynamic> args;

  String str(String key) {
    final v = args[key];
    if (v == null) return '';
    return v.toString().trim();
  }

  int? integer(String key) {
    final v = args[key];
    if (v is int) return v;
    if (v is num) return v.round();
    return int.tryParse(v?.toString().trim() ?? '');
  }

  @override
  String toString() => args.isEmpty ? name : '$name ${jsonEncode(args)}';
}

/// Azioni che il modello può usare.
const Set<String> knownActions = {
  'open_app',
  'read_screen',
  'tap',
  'type',
  'scroll',
  'back',
  'home',
  'wait',
  'call',
  'sms',
  'whatsapp',
  'email',
  'alarm',
  'timer',
  'web_search',
  'open_url',
  'settings',
  'ask',
  'say',
};

/// Sinonimi che i modelli piccoli usano spesso al posto dei nomi giusti.
const Map<String, String> _aliases = {
  'open': 'open_app',
  'launch': 'open_app',
  'apri': 'open_app',
  'click': 'tap',
  'press': 'tap',
  'tap_text': 'tap',
  'input': 'type',
  'write': 'type',
  'type_text': 'type',
  'swipe': 'scroll',
  'go_back': 'back',
  'answer': 'say',
  'speak': 'say',
  'reply': 'say',
  'done': 'say',
  'finish': 'say',
  'respond': 'say',
  'question': 'ask',
  'mail': 'email',
  'send_email': 'email',
  'message': 'sms',
  'send_sms': 'sms',
  'phone': 'call',
  'search': 'web_search',
  'screen': 'read_screen',
  'read': 'read_screen',
};

/// Estrae la prima azione JSON dalla risposta del modello. Tollera testo
/// intorno, blocchi ```json, virgolette singole e nomi alternativi.
/// Restituisce null se non trova niente di utilizzabile.
AgentAction? parseAction(String raw) {
  final obj = _firstJsonObject(raw);
  if (obj == null) return null;
  var name = (obj['action'] ?? obj['tool'] ?? obj['name'] ?? obj['azione'] ?? '').toString().trim().toLowerCase();
  name = name.replaceAll(' ', '_').replaceAll('-', '_');
  name = _aliases[name] ?? name;
  if (!knownActions.contains(name)) return null;
  final args = <String, dynamic>{};
  final nested = obj['args'] ?? obj['params'] ?? obj['parameters'];
  if (nested is Map) {
    nested.forEach((k, v) => args[k.toString()] = v);
  }
  obj.forEach((k, v) {
    if (k == 'action' || k == 'tool' || k == 'name' || k == 'azione' || k == 'args' || k == 'params' || k == 'parameters') {
      return;
    }
    args[k] = v;
  });
  // "name" usato per l'app: {"action":"open_app","name":"WhatsApp"} non
  // passa dal ciclo sopra, quindi lo recuperiamo.
  if (name == 'open_app' && !args.containsKey('app')) {
    final alt = args['package'] ?? args['target'] ?? args['text'];
    if (alt != null) args['app'] = alt;
  }
  return AgentAction(name, args);
}

Map<String, dynamic>? _firstJsonObject(String raw) {
  var s = raw.replaceAll('```json', '').replaceAll('```', '');
  for (var start = s.indexOf('{'); start >= 0; start = s.indexOf('{', start + 1)) {
    final end = _matchingBrace(s, start);
    if (end < 0) continue;
    final chunk = s.substring(start, end + 1);
    final decoded = _tryDecode(chunk) ?? _tryDecode(_relax(chunk));
    if (decoded is Map) {
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    }
  }
  return null;
}

int _matchingBrace(String s, int start) {
  var depth = 0;
  String? quote;
  for (var i = start; i < s.length; i++) {
    final c = s[i];
    if (quote != null) {
      if (c == '\\') {
        i++;
      } else if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '"') {
      quote = c;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

Object? _tryDecode(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

/// Corregge gli errori di JSON più comuni dei modelli piccoli: chiavi
/// senza virgolette, apici singoli, virgola finale.
String _relax(String s) {
  var out = s.replaceAllMapped(RegExp(r"'([^'\\]*)'"), (m) => '"${m[1]!.replaceAll('"', '\\"')}"');
  out = out.replaceAllMapped(RegExp(r'([{,]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:'), (m) => '${m[1]}"${m[2]}":');
  out = out.replaceAll(RegExp(r',\s*}'), '}');
  return out;
}
