/// Le istruzioni per il modello e la costruzione del prompt di ogni passo.

const String systemRules = '''
Sei Dom, assistente vocale che comanda un telefono Android per l'utente (spesso alla guida).
Rispondi SOLO con UN oggetto JSON su una riga: la prossima azione.

Azioni:
{"action":"open_app","app":"nome"}
{"action":"tap","id":12} oppure {"action":"tap","text":"testo"}
{"action":"type","id":5,"text":"testo"}
{"action":"scroll","direction":"down|up"}
{"action":"back"} {"action":"home"} {"action":"wait"} {"action":"read_screen"}
{"action":"call","contact":"nome o numero"}
{"action":"sms","contact":"nome","text":"messaggio"}
{"action":"whatsapp","contact":"nome","text":"messaggio"}
{"action":"email","to":"nome o indirizzo","subject":"oggetto","body":"testo","account":"mittente se detto"}
{"action":"alarm","hour":7,"minute":30}
{"action":"timer","minutes":10}
{"action":"web_search","query":"testo"}
{"action":"settings","panel":"wifi|bluetooth|internet|volume|display|location|airplane"}
{"action":"ask","question":"domanda breve"}
{"action":"say","text":"risposta finale"}

Regole:
- Chiamate, SMS, WhatsApp e mail: usa le azioni dedicate (confermano e inviano da sole), mai il tasto Invia.
- Se manca un dato indispensabile usa "ask". Non inventare.
- Per un'informazione da un'app: apri, leggi lo schermo, scorri o tocca se serve, poi "say".
- "say" chiude il compito: frasi brevi da ascoltare in auto, senza elenchi né simboli, in italiano.
- Mai app di banche, pagamenti o password.
''';

/// Un passo già fatto: azione e risultato.
class StepRecord {
  const StepRecord(this.action, this.result);

  final String action;
  final String result;
}

/// Prompt completo per decidere il prossimo passo.
String buildStepPrompt({
  required String request,
  required List<StepRecord> history,
  required String screen,
  required DateTime now,
  int maxHistory = 6,
}) {
  final b = StringBuffer(systemRules);
  b.writeln();
  b.writeln('Data e ora: ${_formatNow(now)}');
  b.writeln('Richiesta dell\'utente: "$request"');
  if (history.isNotEmpty) {
    b.writeln();
    b.writeln('Passi già fatti:');
    final start = history.length > maxHistory ? history.length - maxHistory : 0;
    if (start > 0) b.writeln('(... $start passi precedenti omessi)');
    for (var i = start; i < history.length; i++) {
      b.writeln('${i + 1}. ${history[i].action} → ${history[i].result}');
    }
  }
  b.writeln();
  b.writeln('Schermo attuale:');
  b.writeln(screen);
  b.writeln();
  b.write('Prossima azione (solo JSON):');
  return b.toString();
}

/// Parte nuova di un passo, quando il modello ricorda già il resto del
/// compito.
String buildDeltaPrompt({required StepRecord? last, required String screen}) {
  final b = StringBuffer();
  if (last != null) b.writeln('Risultato: ${last.result}');
  b.writeln('Schermo attuale:');
  b.writeln(screen);
  b.write('Prossima azione (solo JSON):');
  return b.toString();
}

const List<String> _giorni = ['lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato', 'domenica'];

String _formatNow(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${_giorni[d.weekday - 1]} ${two(d.day)}/${two(d.month)}/${d.year} ore ${two(d.hour)}:${two(d.minute)}';
}
