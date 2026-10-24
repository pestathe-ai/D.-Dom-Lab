/// Un elemento visibile sullo schermo, letto dal servizio di accessibilità.
class ScreenNode {
  const ScreenNode({
    required this.id,
    this.text = '',
    this.desc = '',
    this.viewId = '',
    this.cls = '',
    this.clickable = false,
    this.editable = false,
    this.scrollable = false,
    this.checked,
  });

  factory ScreenNode.fromMap(Map<dynamic, dynamic> m) => ScreenNode(
        id: (m['id'] as num?)?.toInt() ?? -1,
        text: (m['text'] ?? '').toString(),
        desc: (m['desc'] ?? '').toString(),
        viewId: (m['viewId'] ?? '').toString(),
        cls: (m['cls'] ?? '').toString(),
        clickable: m['clickable'] == true,
        editable: m['editable'] == true,
        scrollable: m['scrollable'] == true,
        checked: m['checked'] is bool ? m['checked'] as bool : null,
      );

  final int id;
  final String text;
  final String desc;
  final String viewId;
  final String cls;
  final bool clickable;
  final bool editable;
  final bool scrollable;
  final bool? checked;

  /// Testo mostrato all'utente (o la descrizione, per le icone).
  String get label {
    final t = text.trim();
    final d = desc.trim();
    if (t.isEmpty) return d;
    if (d.isEmpty || d == t) return t;
    return '$t ($d)';
  }

  /// Nome breve dell'id della vista ("com.whatsapp:id/send" → "send").
  String get shortViewId {
    final i = viewId.lastIndexOf('/');
    return i >= 0 ? viewId.substring(i + 1) : viewId;
  }
}

/// Lo schermo attuale: app in primo piano ed elementi.
class ScreenState {
  const ScreenState({required this.package, required this.nodes});

  factory ScreenState.fromMap(Map<dynamic, dynamic> m) => ScreenState(
        package: (m['package'] ?? '').toString(),
        nodes: [
          for (final n in (m['nodes'] as List? ?? const []))
            if (n is Map) ScreenNode.fromMap(n),
        ],
      );

  static const empty = ScreenState(package: '', nodes: []);

  final String package;
  final List<ScreenNode> nodes;

  ScreenNode? byId(int id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// Tutto il testo leggibile, una riga per elemento (per riassumere).
  String plainText({int maxChars = 3000}) {
    final b = StringBuffer();
    String? last;
    for (final n in nodes) {
      final l = n.label.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (l.isEmpty || l == last) continue;
      last = l;
      if (b.length + l.length + 1 > maxChars) break;
      b.writeln(l);
    }
    return b.toString().trim();
  }
}

/// Descrive lo schermo al modello in forma compatta:
/// `[12] Invia (pulsante)` ecc. Restano fuori gli elementi senza testo né
/// funzione. Si ferma a [maxChars] per non riempire il contesto.
String formatScreen(ScreenState s, {int maxChars = 2200}) {
  if (s.nodes.isEmpty) return 'Schermo vuoto o non leggibile.';
  final b = StringBuffer('App in primo piano: ${s.package}\n');
  var cut = false;
  String? last;
  for (final n in s.nodes) {
    var label = n.label.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (label.length > 140) label = '${label.substring(0, 137)}...';
    final tags = <String>[
      if (n.editable) 'campo di testo',
      if (n.clickable && !n.editable) 'tocca',
      if (n.scrollable) 'scorre',
      if (n.checked == true) 'attivo',
      if (n.checked == false) 'spento',
    ];
    if (label.isEmpty) {
      // Pulsanti senza testo: utili solo se hanno un id parlante.
      if (!(n.clickable || n.editable) || n.shortViewId.isEmpty) continue;
      label = '<${n.shortViewId}>';
    }
    final line = '[${n.id}] $label${tags.isEmpty ? '' : ' (${tags.join(', ')})'}';
    if (line == last) continue;
    last = line;
    if (b.length + line.length + 1 > maxChars) {
      cut = true;
      break;
    }
    b.writeln(line);
  }
  if (cut) b.writeln('... (altri elementi: usa scroll per vederli)');
  return b.toString().trim();
}

/// Cerca un elemento per testo (senza maiuscole/accenti), preferendo quelli
/// toccabili e la corrispondenza esatta.
ScreenNode? findNodeByText(ScreenState s, String query, {bool editable = false}) {
  final q = normalize(query);
  if (q.isEmpty) return null;
  ScreenNode? best;
  var bestScore = 0;
  for (final n in s.nodes) {
    if (editable && !n.editable) continue;
    final t = normalize(n.text);
    final d = normalize(n.desc);
    final v = normalize(n.shortViewId.replaceAll('_', ' '));
    var score = 0;
    if (t == q || d == q) {
      score = 100;
    } else if (t.startsWith(q) || d.startsWith(q)) {
      score = 70;
    } else if (t.contains(q) || d.contains(q)) {
      score = 50;
    } else if (v == q) {
      score = 40;
    } else if (q.length > 3 && (q.contains(t) && t.length > 3)) {
      score = 20;
    }
    if (score == 0) continue;
    if (n.clickable || n.editable) score += 5;
    if (score > bestScore) {
      best = n;
      bestScore = score;
    }
  }
  return best;
}

/// Minuscolo, senza accenti e spazi doppi: per confrontare i testi.
String normalize(String s) {
  const from = 'àáâäãèéêëìíîïòóôöõùúûüçñ';
  const to = 'aaaaaeeeeiiiiooooouuuucn';
  final lower = s.toLowerCase();
  final b = StringBuffer();
  for (final r in lower.runes) {
    final c = String.fromCharCode(r);
    final i = from.indexOf(c);
    b.write(i >= 0 ? to[i] : c);
  }
  return b.toString().replaceAll(RegExp(r'[^a-z0-9@.+ ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}
