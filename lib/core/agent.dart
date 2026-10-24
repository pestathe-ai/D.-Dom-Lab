import 'actions.dart';
import 'apps.dart';
import 'contacts.dart';
import 'prompt.dart';
import 'quick.dart';
import 'screen.dart';

/// Quello che l'agente può fare sul telefono (implementato in Kotlin; nei
/// test da un telefono finto).
abstract class Phone {
  Future<ScreenState> screen();
  Future<List<InstalledApp>> apps();
  Future<bool> openApp(String package);
  Future<bool> tap(int id);
  Future<bool> typeText(int id, String text);
  Future<bool> scroll(String direction);
  Future<bool> globalAction(String action);
  Future<List<Contact>> findContacts(String query);
  Future<bool> call(String number);
  Future<bool> sendSms(String number, String text);
  Future<bool> openWhatsApp(String phone, String text);
  Future<bool> composeEmail(String to, String subject, String body);
  Future<bool> setAlarm(int hour, int minute, String label);
  Future<bool> setTimer(int seconds, String label);
  Future<bool> openUrl(String url);
  Future<bool> openSettings(String panel);
  Future<void> pause(Duration d);
}

/// Voce: parlare e ascoltare.
abstract class Voice {
  Future<void> say(String text);

  /// Testo riconosciuto, o null se l'utente non ha detto niente.
  Future<String?> listen();
}

/// Il modello linguistico.
abstract class Brain {
  /// [prompt] è il prompt completo; [delta] solo la parte nuova rispetto al
  /// passo precedente dello stesso compito (il modello può usare l'una o
  /// l'altra).
  Future<String?> complete(String prompt, {String? delta});

  /// Fine del compito.
  Future<void> reset();

  /// Spiegazione dell'ultimo errore (chiave, rete, limiti), se c'è.
  String? get lastError;
}

/// Una riga del registro mostrato a schermo.
class LogEntry {
  const LogEntry(this.kind, this.text);

  /// 'user', 'dom', 'step', 'error'
  final String kind;
  final String text;
}

/// Il ciclo dell'assistente: chiede al modello un'azione alla volta, la
/// esegue, guarda lo schermo e riparte, finché il modello non risponde.
/// Le azioni che inviano o chiamano chiedono sempre conferma a voce.
class Agent {
  Agent({
    required this.phone,
    required this.voice,
    required this.brain,
    this.ownPackage = '',
    this.maxSteps = 15,
    this.onLog,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Phone phone;
  final Voice voice;
  final Brain brain;
  final String ownPackage;
  final int maxSteps;
  final void Function(LogEntry)? onLog;
  final DateTime Function() _clock;

  bool _stop = false;
  List<InstalledApp>? _apps;

  /// Ferma il compito in corso al prossimo passo.
  void stop() => _stop = true;

  void _log(String kind, String text) => onLog?.call(LogEntry(kind, text));

  Future<void> _say(String text) async {
    _log('dom', text);
    await voice.say(text);
  }

  /// Esegue una richiesta. Restituisce l'ultima frase detta all'utente.
  Future<String> run(String request) async {
    _stop = false;
    _log('user', request);
    try {
      return await _run(request);
    } finally {
      await brain.reset();
    }
  }

  Future<String> _run(String request) async {
    final history = <StepRecord>[];

    // Comandi comuni: subito, senza il modello.
    final quick = parseQuick(request);
    if (quick != null) {
      _log('step', '⚡ ${quick.action}');
      final outcome = await _execute(quick.action);
      if (outcome.finalMessage != null) return _finish(outcome.finalMessage!);
      if (quick.followUp == null && outcome.ok) return _finish(outcome.result);
      // Serve il modello (domanda sull'app aperta, o app non trovata).
      history.add(StepRecord(quick.action.toString(), outcome.result));
    }

    var invalid = 0;
    var failures = 0;
    for (var step = 0; step < maxSteps; step++) {
      if (_stop) return _finish('Ok, mi fermo.');
      final screen = await _screenText();
      final prompt = buildStepPrompt(request: request, history: history, screen: screen, now: _clock());
      final delta = step == 0 ? null : buildDeltaPrompt(last: history.isEmpty ? null : history.last, screen: screen);
      final watch = Stopwatch()..start();
      final raw = await brain.complete(prompt, delta: delta);
      watch.stop();
      if (raw == null) return _finish(brain.lastError ?? 'Il modello non risponde. Riprova tra poco.');
      final action = parseAction(raw);
      final secs = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
      if (action == null) {
        invalid++;
        _log('step', '? risposta non valida ($secs s)');
        history.add(StepRecord('(risposta non valida)', 'Rispondi solo con UN oggetto JSON con il campo "action".'));
        if (invalid >= 3) return _finish('Scusa, non ho capito come fare. Puoi ripetere in un altro modo?');
        continue;
      }
      _log('step', '$action ($secs s)');
      if (action.name == 'say') {
        final text = action.str('text').isEmpty ? 'Fatto.' : action.str('text');
        return _finish(text);
      }
      final outcome = await _execute(action);
      if (outcome.finalMessage != null) return _finish(outcome.finalMessage!);
      history.add(StepRecord(action.toString(), outcome.result));
      failures = outcome.ok ? 0 : failures + 1;
      if (failures >= 3) {
        // Il modello è bloccato: chiediamo all'utente.
        final answer = await _ask('Non riesco ad andare avanti. Come vuoi che proceda?');
        if (answer == null) return _finish('Lascio stare, non ci sono riuscito.');
        history.add(StepRecord('ask', 'L\'utente risponde: "$answer"'));
        failures = 0;
      }
    }
    return _finish('Ci sto mettendo troppo: mi fermo qui.');
  }

  Future<String> _finish(String text) async {
    await _say(text);
    return text;
  }

  Future<String> _screenText() async {
    final s = await phone.screen();
    if (s.package.isEmpty || s.package == ownPackage) {
      return 'Nessuna app aperta: sei nella schermata dell\'assistente.';
    }
    if (isBlockedApp(package: s.package)) {
      return 'App sensibile (banca/pagamenti) in primo piano: non leggibile.';
    }
    return formatScreen(s);
  }

  /// Fa una domanda e aspetta la risposta (riprova una volta se silenzio).
  Future<String?> _ask(String question) async {
    await _say(question);
    for (var i = 0; i < 2; i++) {
      final a = await voice.listen();
      if (a != null && a.trim().isNotEmpty) {
        _log('user', a);
        return a.trim();
      }
      if (i == 0) await _say('Non ti ho sentito. ${question.length < 80 ? question : 'Ripeti, per favore.'}');
    }
    return null;
  }

  /// Chiede conferma: true solo con un sì chiaro.
  Future<bool> _confirm(String summary) async {
    var a = await _ask(summary);
    for (var i = 0; i < 2 && a != null; i++) {
      final yn = parseYesNo(a);
      if (yn != null) return yn;
      a = await _ask('Scusa, sì o no?');
    }
    return false;
  }

  Future<_Outcome> _execute(AgentAction a) async {
    switch (a.name) {
      case 'ask':
        final q = a.str('question').isEmpty ? a.str('text') : a.str('question');
        final answer = await _ask(q.isEmpty ? 'Puoi spiegarmi meglio?' : q);
        if (answer == null) return const _Outcome.end('Va bene, lascio stare.');
        return _Outcome('L\'utente risponde: "$answer"');
      case 'open_app':
        return _openApp(a.str('app'));
      case 'read_screen':
        return const _Outcome('Schermo letto (vedi sotto).');
      case 'wait':
        await phone.pause(const Duration(seconds: 2));
        return const _Outcome('Atteso 2 secondi.');
      case 'back':
      case 'home':
        final ok = await phone.globalAction(a.name);
        await phone.pause(const Duration(milliseconds: 900));
        return ok ? const _Outcome('Fatto.') : const _Outcome.fail('Non riuscito.');
      case 'scroll':
        final dir = a.str('direction') == 'up' ? 'up' : 'down';
        final ok = await phone.scroll(dir);
        await phone.pause(const Duration(milliseconds: 1000));
        return ok ? const _Outcome('Scorso.') : const _Outcome.fail('Niente da scorrere.');
      case 'tap':
        return _tap(a);
      case 'type':
        return _type(a);
      case 'call':
        return _call(a.str('contact'));
      case 'sms':
        return _sms(a.str('contact'), a.str('text'));
      case 'whatsapp':
        return _whatsapp(a.str('contact'), a.str('text'));
      case 'email':
        return _email(a);
      case 'alarm':
        final h = a.integer('hour');
        final m = a.integer('minute') ?? a.integer('minutes') ?? 0;
        if (h == null || h < 0 || h > 23 || m < 0 || m > 59) return const _Outcome.fail('Ora non valida: chiedi l\'ora.');
        final ok = await phone.setAlarm(h, m, a.str('label'));
        return ok ? _Outcome('Sveglia impostata alle $h:${m.toString().padLeft(2, '0')}.') : const _Outcome.fail('Sveglia non impostata.');
      case 'timer':
        final min = a.integer('minutes') ?? 0;
        final sec = (a.integer('seconds') ?? 0) + min * 60;
        if (sec <= 0) return const _Outcome.fail('Durata non valida: chiedi quanto tempo.');
        final ok = await phone.setTimer(sec, a.str('label'));
        return ok ? _Outcome('Timer di ${_humanDuration(sec)} avviato.') : const _Outcome.fail('Timer non avviato.');
      case 'web_search':
        final q = a.str('query');
        if (q.isEmpty) return const _Outcome.fail('Manca cosa cercare.');
        final ok = await phone.openUrl('https://www.google.com/search?q=${Uri.encodeQueryComponent(q)}');
        await phone.pause(const Duration(seconds: 3));
        return ok ? const _Outcome('Ricerca aperta nel browser.') : const _Outcome.fail('Browser non aperto.');
      case 'open_url':
        var url = a.str('url');
        if (url.isEmpty) return const _Outcome.fail('Manca l\'indirizzo.');
        if (!url.startsWith('http')) url = 'https://$url';
        final ok = await phone.openUrl(url);
        await phone.pause(const Duration(seconds: 3));
        return ok ? const _Outcome('Pagina aperta.') : const _Outcome.fail('Pagina non aperta.');
      case 'settings':
        final ok = await phone.openSettings(a.str('panel'));
        await phone.pause(const Duration(milliseconds: 1500));
        return ok ? const _Outcome('Impostazioni aperte: ora tocca l\'interruttore giusto.') : const _Outcome.fail('Impostazioni non aperte.');
    }
    return _Outcome.fail('Azione ${a.name} non supportata.');
  }

  Future<_Outcome> _openApp(String name) async {
    if (name.isEmpty) return const _Outcome.fail('Manca il nome dell\'app.');
    final apps = _apps ??= await phone.apps();
    final app = findApp(apps, name);
    if (app == null) {
      return _Outcome.fail('App "$name" non trovata sul telefono.');
    }
    if (isBlockedApp(label: app.label, package: app.package)) {
      return _Outcome.end('${app.label} è un\'app di banca o pagamenti: per sicurezza non la apro.');
    }
    final ok = await phone.openApp(app.package);
    if (!ok) return _Outcome.fail('Non riesco ad aprire ${app.label}.');
    // Aspetta che l'app sia davvero in primo piano (al massimo 4 secondi).
    for (var i = 0; i < 13; i++) {
      await phone.pause(const Duration(milliseconds: 300));
      final s = await phone.screen();
      if (s.package == app.package && s.nodes.length > 2) break;
    }
    await phone.pause(const Duration(milliseconds: 500));
    return _Outcome('Ho aperto ${app.label}.');
  }

  Future<ScreenState?> _actionableScreen() async {
    final s = await phone.screen();
    if (isBlockedApp(package: s.package)) return null;
    return s;
  }

  Future<_Outcome> _tap(AgentAction a) async {
    final s = await _actionableScreen();
    if (s == null) return const _Outcome.end('Questa è un\'app sensibile: non tocco niente.');
    ScreenNode? node;
    final id = a.integer('id');
    if (id != null) node = s.byId(id);
    if (node == null && a.str('text').isNotEmpty) node = findNodeByText(s, a.str('text'));
    if (node == null) return const _Outcome.fail('Elemento non trovato sullo schermo.');
    if (isRiskyLabel(node.label) || isRiskyLabel(node.shortViewId)) {
      final ok = await _confirm('Sto per toccare "${node.label.isEmpty ? node.shortViewId : node.label}". Confermi?');
      if (!ok) return const _Outcome.end('Ok, non lo tocco.');
    }
    final ok = await phone.tap(node.id);
    await phone.pause(const Duration(milliseconds: 800));
    return ok ? _Outcome('Toccato "${node.label}".') : const _Outcome.fail('Tocco non riuscito.');
  }

  Future<_Outcome> _type(AgentAction a) async {
    final s = await _actionableScreen();
    if (s == null) return const _Outcome.end('Questa è un\'app sensibile: non scrivo niente.');
    final text = a.str('text');
    if (text.isEmpty) return const _Outcome.fail('Manca il testo da scrivere.');
    ScreenNode? node;
    final id = a.integer('id');
    if (id != null) node = s.byId(id);
    if (node == null || !node.editable) {
      final edits = s.nodes.where((n) => n.editable).toList();
      if (edits.length == 1) node = edits.first;
    }
    if (node == null) return const _Outcome.fail('Campo di testo non trovato.');
    final ok = await phone.typeText(node.id, text);
    await phone.pause(const Duration(milliseconds: 700));
    return ok ? const _Outcome('Testo scritto.') : const _Outcome.fail('Scrittura non riuscita.');
  }

  /// Trova il contatto giusto; se ce ne sono più di uno chiede quale.
  /// Restituisce null se l'utente non sceglie (e in quel caso ha già
  /// spiegato il motivo in [_lastResolveError]).
  String? _lastResolveError;

  Future<Contact?> _resolveContact(String who, {required bool needEmail}) async {
    _lastResolveError = null;
    if (who.isEmpty) {
      final a = await _ask(needEmail ? 'A chi devo scrivere?' : 'A chi?');
      if (a == null) {
        _lastResolveError = 'Nessun destinatario.';
        return null;
      }
      who = a;
    }
    if (!needEmail && looksLikePhone(who)) return Contact(name: who, phones: [who]);
    if (needEmail && looksLikeEmail(who)) return Contact(name: who, emails: [who]);
    var found = rankContacts(await phone.findContacts(who), who);
    found = found.where((c) => needEmail ? c.emails.isNotEmpty : c.phones.isNotEmpty).toList();
    if (found.isEmpty) {
      final a = await _ask('Non trovo $who in rubrica${needEmail ? ' con un indirizzo email' : ''}. Mi dici il nome esatto o ${needEmail ? 'l\'indirizzo' : 'il numero'}?');
      if (a == null) {
        _lastResolveError = 'Contatto non trovato.';
        return null;
      }
      if (!needEmail && looksLikePhone(a)) return Contact(name: a, phones: [a]);
      if (needEmail && looksLikeEmail(a.replaceAll(' chiocciola ', '@').replaceAll(' punto ', '.').replaceAll(' ', ''))) {
        final mail = a.replaceAll(' chiocciola ', '@').replaceAll(' punto ', '.').replaceAll(' ', '');
        return Contact(name: mail, emails: [mail]);
      }
      found = rankContacts(await phone.findContacts(a), a)
          .where((c) => needEmail ? c.emails.isNotEmpty : c.phones.isNotEmpty)
          .toList();
      if (found.isEmpty) {
        _lastResolveError = 'Contatto "$a" non trovato in rubrica.';
        return null;
      }
    }
    if (found.length > 1) {
      final names = found.take(4).map((c) => c.name).toList();
      final a = await _ask('Ho trovato ${names.length} contatti: ${_joinOr(names)}. Quale?');
      final i = a == null ? null : pickOption(names, a);
      if (i == null) {
        _lastResolveError = 'Non ho capito quale contatto.';
        return null;
      }
      return found[i];
    }
    var c = found.first;
    final list = needEmail ? c.emails : c.phones;
    if (list.toSet().length > 1) {
      final opts = list.toSet().take(3).toList();
      final a = await _ask('${c.name} ha più ${needEmail ? 'indirizzi' : 'numeri'}: ${_joinOr(opts.map(_speakable).toList())}. Quale uso?');
      final i = a == null ? null : pickOption(opts, a);
      if (i == null) {
        _lastResolveError = 'Non ho capito quale ${needEmail ? 'indirizzo' : 'numero'}.';
        return null;
      }
      c = needEmail ? Contact(name: c.name, emails: [opts[i]]) : Contact(name: c.name, phones: [opts[i]]);
    }
    return c;
  }

  Future<String?> _textToSend(String text) async {
    if (text.trim().isNotEmpty) return text.trim();
    return _ask('Cosa devo scrivere?');
  }

  Future<_Outcome> _call(String who) async {
    final c = await _resolveContact(who, needEmail: false);
    if (c == null) return _Outcome.end(_lastResolveError ?? 'Non so chi chiamare.');
    if (!await _confirm('Chiamo ${c.name}?')) return const _Outcome.end('Ok, non chiamo.');
    final ok = await phone.call(cleanPhone(c.phones.first));
    return ok ? _Outcome.end('Chiamo ${c.name}.') : const _Outcome.end('Non riesco a fare la chiamata. Controlla il permesso Telefono.');
  }

  Future<_Outcome> _sms(String who, String text) async {
    final c = await _resolveContact(who, needEmail: false);
    if (c == null) return _Outcome.end(_lastResolveError ?? 'Non so a chi scrivere.');
    final body = await _textToSend(text);
    if (body == null) return const _Outcome.end('Va bene, niente messaggio.');
    if (!await _confirm('Mando un SMS a ${c.name}: "$body". Invio?')) return const _Outcome.end('Ok, non lo mando.');
    final ok = await phone.sendSms(cleanPhone(c.phones.first), body);
    return ok ? _Outcome.end('Messaggio inviato a ${c.name}.') : const _Outcome.end('SMS non inviato. Controlla il permesso SMS.');
  }

  Future<_Outcome> _whatsapp(String who, String text) async {
    final c = await _resolveContact(who, needEmail: false);
    if (c == null) return _Outcome.end(_lastResolveError ?? 'Non so a chi scrivere.');
    final body = await _textToSend(text);
    if (body == null) return const _Outcome.end('Va bene, niente messaggio.');
    if (!await _confirm('Mando su WhatsApp a ${c.name}: "$body". Invio?')) return const _Outcome.end('Ok, non lo mando.');
    if (!await phone.openWhatsApp(internationalPhone(c.phones.first), body)) {
      return const _Outcome.end('Non riesco ad aprire WhatsApp.');
    }
    final sent = await _pressSend(const ['send', 'invia', 'send button']);
    return sent
        ? _Outcome.end('Messaggio WhatsApp inviato a ${c.name}.')
        : const _Outcome.end('Ho preparato il messaggio su WhatsApp ma non trovo il tasto Invia: premilo tu quando puoi.');
  }

  Future<_Outcome> _email(AgentAction a) async {
    final c = await _resolveContact(a.str('to'), needEmail: true);
    if (c == null) return _Outcome.end(_lastResolveError ?? 'Non so a chi scrivere.');
    final body = await _textToSend(a.str('body').isEmpty ? a.str('text') : a.str('body'));
    if (body == null) return const _Outcome.end('Va bene, niente mail.');
    var subject = a.str('subject');
    if (subject.isEmpty) subject = _autoSubject(body);
    final account = a.str('account');
    final from = account.isEmpty ? '' : ' dall\'account $account';
    if (!await _confirm('Mando una mail a ${c.name}$from, oggetto "$subject": "$body". Invio?')) {
      return const _Outcome.end('Ok, non la mando.');
    }
    if (!await phone.composeEmail(c.emails.first, subject, body)) {
      return const _Outcome.end('Non riesco ad aprire l\'app della posta.');
    }
    await phone.pause(const Duration(milliseconds: 2500));
    if (account.isNotEmpty && !await _chooseAccount(account)) {
      return _Outcome.end('Ho preparato la mail ma non riesco a scegliere l\'account $account: controllala tu prima di inviarla.');
    }
    final sent = await _pressSend(const ['send', 'invia']);
    return sent
        ? _Outcome.end('Mail inviata a ${c.name}.')
        : const _Outcome.end('Ho preparato la mail ma non trovo il tasto Invia: premilo tu quando puoi.');
  }

  /// Nella schermata di scrittura di Gmail tocca il mittente e sceglie
  /// l'account che contiene [account].
  Future<bool> _chooseAccount(String account) async {
    var s = await phone.screen();
    final q = normalize(account);
    // Già selezionato?
    final from = s.nodes.where((n) => n.shortViewId.contains('from')).toList();
    if (from.any((n) => normalize(n.label).contains(q))) return true;
    final clickableFrom = from.where((n) => n.clickable).toList();
    final opener = clickableFrom.isNotEmpty ? clickableFrom.first : findNodeByText(s, 'da');
    if (opener == null) return false;
    await phone.tap(opener.id);
    await phone.pause(const Duration(milliseconds: 1200));
    s = await phone.screen();
    final choice = findNodeByText(s, account);
    if (choice == null) {
      await phone.globalAction('back');
      return false;
    }
    await phone.tap(choice.id);
    await phone.pause(const Duration(milliseconds: 1000));
    return true;
  }

  /// Cerca e tocca il pulsante di invio nella schermata attuale (riprova
  /// qualche volta mentre l'app si apre).
  Future<bool> _pressSend(List<String> names) async {
    for (var i = 0; i < 4; i++) {
      await phone.pause(Duration(milliseconds: i == 0 ? 2000 : 1200));
      final s = await phone.screen();
      ScreenNode? node;
      for (final n in s.nodes) {
        if (!n.clickable) continue;
        final v = n.shortViewId.toLowerCase();
        final l = normalize(n.label);
        if (names.contains(v) || names.contains(l)) {
          node = n;
          break;
        }
      }
      if (node != null) {
        final ok = await phone.tap(node.id);
        await phone.pause(const Duration(milliseconds: 800));
        return ok;
      }
    }
    return false;
  }
}

/// Pulsanti che inviano, chiamano o pagano: serve conferma.
bool isRiskyLabel(String label) {
  final l = ' ${normalize(label.replaceAll('_', ' '))} ';
  const words = [' invia ', ' send ', ' chiama ', ' call ', ' paga ', ' pay ', ' acquista ', ' compra ', ' buy ', ' ordina ', ' elimina ', ' delete ', ' cancella ', ' pubblica ', ' post ', ' condividi ', ' share '];
  return words.any(l.contains);
}

String _humanDuration(int sec) {
  if (sec % 3600 == 0) return sec == 3600 ? 'un\'ora' : '${sec ~/ 3600} ore';
  if (sec % 60 == 0) return sec == 60 ? 'un minuto' : '${sec ~/ 60} minuti';
  if (sec < 60) return '$sec secondi';
  return '${sec ~/ 60} minuti e ${sec % 60} secondi';
}

String _joinOr(List<String> items) {
  if (items.length <= 1) return items.join();
  return '${items.sublist(0, items.length - 1).join(', ')} oppure ${items.last}';
}

String _speakable(String s) => s.contains('@') ? s : s.replaceAll(RegExp(r'\s+'), '');

String _autoSubject(String body) {
  final words = body.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).take(6).join(' ');
  final s = words.replaceAll(RegExp(r'[.,;:!?]+$'), '');
  if (s.isEmpty) return 'Messaggio';
  return s[0].toUpperCase() + s.substring(1);
}

class _Outcome {
  const _Outcome(this.result)
      : ok = true,
        finalMessage = null;
  const _Outcome.fail(this.result)
      : ok = false,
        finalMessage = null;
  const _Outcome.end(String message)
      : result = message,
        ok = true,
        finalMessage = message;

  final String result;
  final bool ok;
  final String? finalMessage;
}
