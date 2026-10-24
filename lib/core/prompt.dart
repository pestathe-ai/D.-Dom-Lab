/// Le istruzioni per il modello e la costruzione del prompt di ogni passo.

const String systemRules = '''
Sei Dom, un assistente vocale che comanda un telefono Android al posto dell'utente, che spesso sta guidando.
Rispondi SEMPRE e SOLO con UN oggetto JSON su una riga: la prossima azione da fare. Niente altro testo.

Azioni disponibili:
{"action":"open_app","app":"nome app"}
{"action":"read_screen"} legge di nuovo lo schermo
{"action":"tap","id":12} tocca l'elemento [12] dello schermo
{"action":"tap","text":"Juventus"} tocca l'elemento con quel testo
{"action":"type","id":5,"text":"testo"} scrive nel campo [5]
{"action":"scroll","direction":"down"} oppure "up"
{"action":"back"}  {"action":"home"}  {"action":"wait"}
{"action":"call","contact":"nome o numero"}
{"action":"sms","contact":"nome o numero","text":"messaggio"}
{"action":"whatsapp","contact":"nome","text":"messaggio"}
{"action":"email","to":"nome o indirizzo","subject":"oggetto","body":"testo","account":"account mittente se indicato"}
{"action":"alarm","hour":7,"minute":30,"label":"etichetta"}
{"action":"timer","minutes":10,"label":"etichetta"}
{"action":"web_search","query":"cosa cercare"}
{"action":"open_url","url":"https://..."}
{"action":"settings","panel":"wifi|bluetooth|internet|volume|nfc|display|battery|location|airplane|general"}
{"action":"ask","question":"domanda breve all'utente"}
{"action":"say","text":"risposta finale da dire all'utente"}

Regole:
- Una sola azione per risposta. Dopo ogni azione ricevi il risultato e lo schermo.
- Per chiamare, mandare SMS, WhatsApp o mail usa le azioni dedicate: chiedono loro conferma all'utente e inviano. Non toccare tu il pulsante Invia.
- Se manca un'informazione indispensabile (a chi, cosa scrivere, quale app) usa "ask". Non inventare dati.
- Se qualcosa non funziona due volte di seguito, usa "ask" per chiedere come proseguire.
- Per sapere un'informazione da un'app: open_app, poi leggi lo schermo, tocca o scorri se serve, poi "say" con un riassunto breve.
- Quando il compito è finito, o se è solo una domanda, usa "say". Frasi brevi e naturali, adatte a essere ascoltate in auto, senza elenchi né simboli.
- Non aprire mai app di banche, pagamenti o password.
- Parla sempre in italiano.
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
  int maxHistory = 8,
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

const List<String> _giorni = ['lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato', 'domenica'];

String _formatNow(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${_giorni[d.weekday - 1]} ${two(d.day)}/${two(d.month)}/${d.year} ore ${two(d.hour)}:${two(d.minute)}';
}
