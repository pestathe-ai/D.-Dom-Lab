import 'screen.dart' show normalize;

/// Un'app installata che si può aprire.
class InstalledApp {
  const InstalledApp(this.label, this.package);

  factory InstalledApp.fromMap(Map<dynamic, dynamic> m) =>
      InstalledApp((m['label'] ?? '').toString(), (m['package'] ?? '').toString());

  final String label;
  final String package;

  @override
  String toString() => '$label ($package)';
}

/// Nomi comuni detti a voce → parole che compaiono nel nome dell'app.
const Map<String, List<String>> _spoken = {
  'posta': ['gmail', 'posta', 'mail', 'email'],
  'mail': ['gmail', 'posta', 'mail', 'email'],
  'email': ['gmail', 'posta', 'mail', 'email'],
  'messaggi': ['messaggi', 'messages', 'sms'],
  'telefono': ['telefono', 'phone', 'dialer'],
  'fotocamera': ['fotocamera', 'camera'],
  'foto': ['galleria', 'gallery', 'foto', 'photos'],
  'galleria': ['galleria', 'gallery', 'foto', 'photos'],
  'mappe': ['maps', 'mappe'],
  'maps': ['maps', 'mappe'],
  'impostazioni': ['impostazioni', 'settings'],
  'calendario': ['calendario', 'calendar'],
  'orologio': ['orologio', 'clock'],
  'musica': ['music', 'musica', 'spotify'],
  'browser': ['chrome', 'browser'],
  'internet': ['chrome', 'browser'],
  'tutto sport': ['tuttosport'],
  'whats app': ['whatsapp'],
  'you tube': ['youtube'],
};

/// Trova l'app più simile al nome detto. Null se nessuna somiglia.
InstalledApp? findApp(List<InstalledApp> apps, String spoken) {
  final q = normalize(spoken);
  if (q.isEmpty) return null;
  final qNoSpace = q.replaceAll(' ', '');
  final alts = <String>{q, qNoSpace, ...?_spoken[q]};
  InstalledApp? best;
  var bestScore = 0;
  for (final a in apps) {
    final l = normalize(a.label);
    final lNoSpace = l.replaceAll(' ', '');
    final p = a.package.toLowerCase();
    var score = 0;
    if (l == q || lNoSpace == qNoSpace) {
      score = 100;
    } else if (p == spoken.trim().toLowerCase()) {
      score = 100;
    } else if (alts.any((x) => x.isNotEmpty && l == x)) {
      score = 90;
    } else if (l.startsWith(q) || lNoSpace.startsWith(qNoSpace)) {
      score = 80;
    } else if (alts.any((x) => x.length > 2 && (l.contains(x) || lNoSpace.contains(x)))) {
      score = 60;
    } else if (alts.any((x) => x.length > 3 && p.contains(x.replaceAll(' ', '')))) {
      score = 45;
    } else if (l.length > 3 && q.contains(l)) {
      score = 35;
    }
    if (score == 0) continue;
    // A parità, l'app con il nome più corto (es. "Gmail" e non "Gmail Go").
    score = score * 100 - l.length;
    if (score > bestScore) {
      best = a;
      bestScore = score;
    }
  }
  return best;
}

/// Parole che indicano app di banca, pagamenti e simili: l'assistente non
/// le apre e non le comanda.
const List<String> _blockedWords = [
  'bank',
  'banca',
  'banco',
  'bancaria',
  'intesa',
  'unicredit',
  'fineco',
  'mediolanum',
  'bper',
  'credem',
  'poste',
  'bancoposta',
  'postepay',
  'paypal',
  'satispay',
  'revolut',
  'n26',
  'hype',
  'wallet',
  'pay',
  'nexi',
  'amex',
  'american express',
  'visa',
  'mastercard',
  'crypto',
  'binance',
  'coinbase',
  'trading',
  'directa',
  'degiro',
  'scalable',
  'trade republic',
  'carta',
  'spid',
  'authenticator',
  'otp',
  'password',
  'keepass',
  'bitwarden',
  '1password',
  'lastpass',
];

/// Pacchetti esplicitamente bloccati anche se il nome non lo dice.
const List<String> _blockedPackages = [
  'com.google.android.apps.walletnfcrel',
  'com.google.android.apps.authenticator2',
  'com.paypal.android',
  'satispay',
  'it.poste',
  'posteitaliane',
  'com.revolut',
  'de.number26',
  'com.hype',
  'com.nexi',
  'com.unicredit',
  'it.intesasanpaolo',
  'com.latuabancaperandroid',
  'it.bnl',
  'com.binance',
  'com.coinbase',
];

/// Vero se l'app è sensibile (banca, pagamenti, password).
bool isBlockedApp({String label = '', String package = ''}) {
  final l = ' ${normalize(label)} ';
  final p = package.toLowerCase();
  if (_blockedPackages.any(p.contains)) return true;
  for (final w in _blockedWords) {
    // Parole intere, così "Tuttosport" non viene bloccata per "pay"... e
    // "Spotify" non per "pay" o "otp".
    if (l.contains(' $w ')) return true;
    if (w.length > 4 && p.split('.').any((part) => part == w)) return true;
  }
  return false;
}
