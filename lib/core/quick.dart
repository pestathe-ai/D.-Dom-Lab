import 'actions.dart';

/// Un comando riconosciuto al volo, senza chiedere al modello.
class QuickCommand {
  const QuickCommand(this.action, {this.followUp});

  final AgentAction action;

  /// Per "apri X e dimmi Y": la domanda da girare al modello dopo aver
  /// aperto l'app.
  final String? followUp;
}

RegExp _re(String p) => RegExp(p, caseSensitive: false, unicode: true);

final _call = _re(r"^(?:chiama|telefona(?: a)?|fai una (?:telefonata|chiamata) a|chiamami)\s+(.+)$");
final _whatsapp1 = _re(
    r"^(?:manda|invia|scrivi|mandami)\s+(?:un\s+)?(?:messaggio\s+)?(?:whatsapp\s+|su\s+whatsapp\s+)?a\s+(.+?)\s+su\s+whatsapp\s*(?:che|dicendo|dicendogli|dicendole|con scritto|:|,)?\s*(.+)$");
final _whatsapp2 = _re(
    r"^(?:manda|invia|scrivi)\s+(?:un\s+)?(?:messaggio\s+)?(?:su\s+)?whatsapp\s+a\s+(.+?)\s*(?:che|dicendo|dicendogli|dicendole|con scritto|:|,)\s*(.+)$");
final _sms = _re(
    r"^(?:manda|invia|scrivi)\s+(?:un\s+)?(?:sms|messaggio(?:\s+di\s+testo)?)\s+a\s+(.+?)\s*(?:che|dicendo|dicendogli|dicendole|con scritto|:|,)\s*(.+)$");
final _open = _re(r"^(?:apri|avvia|lancia|fai partire|vai su|vai in|apri l'app|apri l app|apri l'applicazione)\s+(.+?)(?:\s+e\s+((?:dimmi|leggimi|leggi|controlla|guarda|cerca|vedi|fammi sapere|trova)\b.*))?$");
final _alarm = _re(r"^(?:metti\s+|mettimi\s+|imposta\s+|punta\s+)?(?:una\s+)?(?:la\s+)?(?:sveglia|svegliami)\s+(?:alle|per le|a|domani alle)\s+(.+)$");
final _timer = _re(r"^(?:metti\s+|mettimi\s+|imposta\s+|avvia\s+|fai partire\s+)?(?:un\s+)?timer\s+(?:di\s+|da\s+|per\s+)?(.+)$");
final _search = _re(r"^(?:cerca|cercami|cerca su google|cerca su internet|googla)\s+(.+)$");
final _back = _re(r"^(?:torna indietro|indietro|vai indietro)$");
final _home = _re(r"^(?:vai alla home|torna alla home|home|schermata principale|vai alla schermata principale)$");

String _clean(String s) => s.trim().replaceAll(RegExp(r'[.!?]+$'), '').trim();

/// Riconosce i comandi più comuni. Null se serve il modello.
QuickCommand? parseQuick(String spoken) {
  final s = _clean(spoken.replaceAll(RegExp(r'\s+'), ' '));
  if (s.isEmpty) return null;
  // Le mail hanno destinatario, account, oggetto e testo: meglio il modello.
  if (RegExp(r'\b(mail|email|e-mail|posta)\b', caseSensitive: false).hasMatch(s)) return null;

  final wa = _whatsapp1.firstMatch(s) ?? _whatsapp2.firstMatch(s);
  if (wa != null) {
    return QuickCommand(AgentAction('whatsapp', {'contact': _clean(wa[1]!), 'text': _capitalize(_clean(wa[2]!))}));
  }
  final sms = _sms.firstMatch(s);
  if (sms != null) {
    return QuickCommand(AgentAction('sms', {'contact': _clean(sms[1]!), 'text': _capitalize(_clean(sms[2]!))}));
  }
  final call = _call.firstMatch(s);
  if (call != null) {
    final who = _clean(call[1]!).replaceFirst(RegExp(r'^(a|il|la)\s+', caseSensitive: false), '');
    if (who.isNotEmpty) return QuickCommand(AgentAction('call', {'contact': who}));
  }
  final alarm = _alarm.firstMatch(s);
  if (alarm != null) {
    final t = parseTime(alarm[1]!);
    if (t != null) return QuickCommand(AgentAction('alarm', {'hour': t.$1, 'minute': t.$2}));
  }
  final timer = _timer.firstMatch(s);
  if (timer != null) {
    final sec = parseDuration(timer[1]!);
    if (sec != null) return QuickCommand(AgentAction('timer', {'seconds': sec}));
  }
  if (_back.hasMatch(s)) return const QuickCommand(AgentAction('back'));
  if (_home.hasMatch(s)) return const QuickCommand(AgentAction('home'));
  final search = _search.firstMatch(s);
  if (search != null) {
    return QuickCommand(AgentAction('web_search', {'query': _clean(search[1]!)}));
  }
  final open = _open.firstMatch(s);
  if (open != null) {
    final app = _clean(open[1]!).replaceFirst(RegExp(r"^(l'app|l app|l'applicazione|app)\s+", caseSensitive: false), '').replaceFirst(RegExp(r'^(di|del|della)\s+', caseSensitive: false), '');
    if (app.isEmpty || app.split(' ').length > 4) return null;
    final follow = open[2];
    return QuickCommand(AgentAction('open_app', {'app': app}), followUp: follow == null ? null : _clean(follow));
  }
  return null;
}

String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

const Map<String, int> _units = {
  'zero': 0, 'un': 1, 'uno': 1, 'una': 1, 'due': 2, 'tre': 3, 'quattro': 4, 'cinque': 5, 'sei': 6, 'sette': 7,
  'otto': 8, 'nove': 9, 'dieci': 10, 'undici': 11, 'dodici': 12, 'tredici': 13, 'quattordici': 14,
  'quindici': 15, 'sedici': 16, 'diciassette': 17, 'diciotto': 18, 'diciannove': 19,
};
const Map<String, int> _tens = {'venti': 20, 'vent': 20, 'trenta': 30, 'trent': 30, 'quaranta': 40, 'quarant': 40, 'cinquanta': 50, 'cinquant': 50};

/// "sette", "ventitré", "45" → numero.
int? parseNumber(String w) {
  final t = w.trim().toLowerCase().replaceAll('é', 'e').replaceAll('è', 'e');
  final d = int.tryParse(t);
  if (d != null) return d;
  if (_units.containsKey(t)) return _units[t];
  for (final e in _tens.entries) {
    if (t == e.key) return e.value;
    if (t.startsWith(e.key)) {
      final rest = t.substring(e.key.length);
      final u = _units[rest] ?? (rest == 'a' ? 0 : null);
      if (u != null && u < 10) return e.value + u;
    }
  }
  return null;
}

/// "7", "7:30", "7 e mezza", "sette e un quarto", "otto meno dieci",
/// "19 e 45", "mezzogiorno" → (ora, minuti).
(int, int)? parseTime(String raw) {
  var t = raw.toLowerCase().trim().replaceAll(RegExp(r'[.,]$'), '');
  t = t.replaceAll(RegExp(r'\b(del mattino|di mattina|di sera|del pomeriggio|di notte|in punto)\b'), (' ')).trim();
  final evening = RegExp(r'\b(sera|pomeriggio)\b').hasMatch(raw.toLowerCase());
  if (t.startsWith('mezzogiorno')) return (12, 0);
  if (t.startsWith('mezzanotte')) return (0, 0);
  final colon = RegExp(r'^(\d{1,2})[:.](\d{2})').firstMatch(t);
  int h;
  var m = 0;
  if (colon != null) {
    h = int.parse(colon[1]!);
    m = int.parse(colon[2]!);
  } else {
    final parts = t.split(RegExp(r'\s+'));
    final ph = parseNumber(parts.first);
    if (ph == null) return null;
    h = ph;
    final rest = parts.skip(1).join(' ');
    if (rest.startsWith('e mezza') || rest.startsWith('e mezzo') || rest.startsWith('e trenta')) {
      m = 30;
    } else if (rest.startsWith('e un quarto') || rest.startsWith('e quarto')) {
      m = 15;
    } else if (rest.startsWith('e tre quarti')) {
      m = 45;
    } else if (rest.startsWith('meno un quarto') || rest.startsWith('meno quarto')) {
      h = h - 1;
      m = 45;
    } else if (rest.startsWith('meno ')) {
      final n = parseNumber(rest.substring(5).split(' ').first);
      if (n == null || n >= 60) return null;
      h = h - 1;
      m = 60 - n;
    } else if (rest.startsWith('e ')) {
      final n = parseNumber(rest.substring(2).split(' ').first);
      if (n == null) return null;
      m = n;
    } else if (rest.isNotEmpty && rest != 'minuti') {
      final n = parseNumber(rest.split(' ').first);
      if (n != null) m = n;
    }
  }
  if (h < 0) h += 24;
  if (evening && h < 12) h += 12;
  if (h > 23 || m < 0 || m > 59) return null;
  return (h, m);
}

/// "5 minuti", "dieci minuti", "un'ora", "30 secondi", "un minuto e mezzo"
/// → secondi.
int? parseDuration(String raw) {
  final t = raw.toLowerCase().replaceAll("un'ora", 'una ora').replaceAll("un ora", 'una ora').trim();
  final m = RegExp(r"^(\S+)\s+(secondi|secondo|minuti|minuto|ore|ora)(\s+e\s+mezz[oa])?").firstMatch(t);
  if (m == null) return null;
  final n = parseNumber(m[1]!);
  if (n == null || n <= 0) return null;
  final unit = m[2]!;
  final mult = unit.startsWith('second') ? 1 : unit.startsWith('minut') ? 60 : 3600;
  var sec = n * mult;
  if (m[3] != null) sec += mult ~/ 2;
  return sec;
}
