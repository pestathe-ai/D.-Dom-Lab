import 'screen.dart' show normalize;

/// Un contatto della rubrica.
class Contact {
  const Contact({required this.name, this.phones = const [], this.emails = const []});

  factory Contact.fromMap(Map<dynamic, dynamic> m) => Contact(
        name: (m['name'] ?? '').toString(),
        phones: [for (final p in (m['phones'] as List? ?? const [])) p.toString()],
        emails: [for (final e in (m['emails'] as List? ?? const [])) e.toString()],
      );

  final String name;
  final List<String> phones;
  final List<String> emails;
}

/// Vero se il testo è già un numero di telefono.
bool looksLikePhone(String s) {
  final digits = s.replaceAll(RegExp(r'[\s\-./()]'), '');
  return RegExp(r'^\+?\d{5,15}$').hasMatch(digits);
}

/// Numero pulito per intent e WhatsApp: solo cifre e + iniziale.
String cleanPhone(String s) {
  final t = s.trim();
  final plus = t.startsWith('+') || t.startsWith('00');
  var digits = t.replaceAll(RegExp(r'\D'), '');
  if (t.startsWith('00')) digits = digits.substring(2);
  return plus ? '+$digits' : digits;
}

/// Numero in formato internazionale senza + (per WhatsApp); i numeri
/// italiani senza prefisso prendono il 39.
String internationalPhone(String s) {
  final c = cleanPhone(s);
  if (c.startsWith('+')) return c.substring(1);
  if (c.startsWith('3') && c.length >= 9 && c.length <= 10) return '39$c';
  return c;
}

bool looksLikeEmail(String s) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(s.trim());

/// Ordina i contatti per somiglianza al nome detto e scarta quelli che non
/// c'entrano. Se uno corrisponde esattamente, resta solo lui.
List<Contact> rankContacts(List<Contact> all, String spoken) {
  final q = normalize(spoken);
  if (q.isEmpty) return const [];
  final words = q.split(' ').where((w) => w.isNotEmpty).toList();
  final scored = <(Contact, int)>[];
  for (final c in all) {
    final n = normalize(c.name);
    if (n.isEmpty) continue;
    var score = 0;
    if (n == q) {
      score = 100;
    } else if (words.every((w) => n.split(' ').contains(w))) {
      score = 80;
    } else if (words.every(n.contains)) {
      score = 60;
    } else if (n.split(' ').any((part) => part.length > 2 && words.contains(part))) {
      score = 30;
    }
    if (score > 0) scored.add((c, score));
  }
  scored.sort((a, b) => b.$2.compareTo(a.$2));
  if (scored.isEmpty) return const [];
  final top = scored.first.$2;
  if (top == 100) return [for (final s in scored) if (s.$2 == 100) s.$1];
  return [for (final s in scored) if (s.$2 == top) s.$1];
}

/// Risposta sì/no detta a voce. Null se non è chiara.
bool? parseYesNo(String answer) {
  final a = ' ${normalize(answer)} ';
  const no = [' no ', ' non ', ' annulla ', ' lascia stare ', ' fermati ', ' stop ', ' aspetta ', ' cancella ', ' negativo '];
  const yes = [' si ', ' sì ', ' ok ', ' okay ', ' va bene ', ' certo ', ' vai ', ' invia ', ' manda ', ' procedi ', ' conferma ', ' confermo ', ' esatto ', ' giusto ', ' perfetto ', ' chiama ', ' yes ', ' affermativo ', ' d accordo '];
  final isNo = no.any(a.contains);
  final isYes = yes.any(a.contains);
  if (isNo && !isYes) return false;
  if (isYes && !isNo) return true;
  if (isYes && isNo) {
    // "no no, va bene" → prevale la prima parola detta.
    final firstNo = no.map(a.indexOf).where((i) => i >= 0).fold<int>(1 << 30, (p, i) => i < p ? i : p);
    final firstYes = yes.map(a.indexOf).where((i) => i >= 0).fold<int>(1 << 30, (p, i) => i < p ? i : p);
    return firstYes < firstNo;
  }
  return null;
}

const List<String> _ordinals = ['primo', 'secondo', 'terzo', 'quarto', 'quinto', 'sesto'];

/// Sceglie un'opzione dalla risposta detta a voce: per nome ("Rossi"), per
/// posizione ("il secondo") o per numero ("2"). Null se non è chiara.
int? pickOption(List<String> options, String answer) {
  final a = normalize(answer);
  if (a.isEmpty) return null;
  for (var i = 0; i < _ordinals.length && i < options.length; i++) {
    final o = _ordinals[i];
    if (RegExp('\\b(${o}|${o.substring(0, o.length - 1)}a)\\b').hasMatch(a)) return i;
  }
  if (a.contains('ultimo') || a.contains('ultima')) return options.length - 1;
  final num = int.tryParse(a.replaceAll(RegExp(r'\D'), ''));
  if (num != null && num >= 1 && num <= options.length && a.replaceAll(RegExp(r'\d'), '').trim().length < 8) {
    return num - 1;
  }
  final words = a.split(' ').where((w) => w.length > 2).toSet();
  var best = -1;
  var bestScore = 0;
  for (var i = 0; i < options.length; i++) {
    final parts = normalize(options[i]).split(' ');
    final score = parts.where(words.contains).length;
    if (score > bestScore) {
      best = i;
      bestScore = score;
    } else if (score == bestScore && score > 0) {
      best = -2; // pari: ambiguo
    }
  }
  return best >= 0 ? best : null;
}
