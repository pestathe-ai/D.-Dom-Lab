import 'package:dom_lab/core/actions.dart';
import 'package:dom_lab/core/agent.dart';
import 'package:dom_lab/core/apps.dart';
import 'package:dom_lab/core/contacts.dart';
import 'package:dom_lab/core/prompt.dart';
import 'package:dom_lab/core/quick.dart';
import 'package:dom_lab/core/screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// Telefono finto: registra le azioni e mostra schermi preparati.
class FakePhone implements Phone {
  FakePhone({this.contacts = const [], this.installed = const []});

  final List<Contact> contacts;
  final List<InstalledApp> installed;
  final List<String> calls = [];

  /// Schermo mostrato per ogni pacchetto aperto.
  final Map<String, ScreenState> screens = {};
  ScreenState current = ScreenState.empty;

  @override
  Future<ScreenState> screen() async => current;

  @override
  Future<List<InstalledApp>> apps() async => installed;

  @override
  Future<bool> openApp(String package) async {
    calls.add('openApp $package');
    current = screens[package] ?? ScreenState(package: package, nodes: const []);
    return true;
  }

  @override
  Future<bool> tap(int id) async {
    final n = current.byId(id);
    calls.add('tap ${n?.label.isNotEmpty == true ? n!.label : n?.shortViewId}');
    return n != null;
  }

  @override
  Future<bool> typeText(int id, String text) async {
    calls.add('type $id $text');
    return true;
  }

  @override
  Future<bool> scroll(String direction) async {
    calls.add('scroll $direction');
    return true;
  }

  @override
  Future<bool> globalAction(String action) async {
    calls.add(action);
    return true;
  }

  @override
  Future<List<Contact>> findContacts(String query) async {
    final q = normalize(query).split(' ').first;
    return contacts.where((c) => normalize(c.name).contains(q)).toList();
  }

  @override
  Future<bool> call(String number) async {
    calls.add('call $number');
    return true;
  }

  @override
  Future<bool> sendSms(String number, String text) async {
    calls.add('sms $number $text');
    return true;
  }

  @override
  Future<bool> openWhatsApp(String phone, String text) async {
    calls.add('whatsapp $phone $text');
    current = whatsappScreen;
    return true;
  }

  @override
  Future<bool> composeEmail(String to, String subject, String body) async {
    calls.add('email $to | $subject | $body');
    current = gmailCompose;
    return true;
  }

  @override
  Future<bool> setAlarm(int hour, int minute, String label) async {
    calls.add('alarm $hour:$minute');
    return true;
  }

  @override
  Future<bool> setTimer(int seconds, String label) async {
    calls.add('timer $seconds');
    return true;
  }

  @override
  Future<bool> openUrl(String url) async {
    calls.add('url $url');
    return true;
  }

  @override
  Future<bool> openSettings(String panel) async {
    calls.add('settings $panel');
    return true;
  }

  @override
  Future<void> pause(Duration d) async {}
}

class FakeVoice implements Voice {
  FakeVoice(this.answers);

  final List<String?> answers;
  final List<String> said = [];

  @override
  Future<void> say(String text) async => said.add(text);

  @override
  Future<String?> listen() async => answers.isEmpty ? null : answers.removeAt(0);
}

class FakeBrain implements Brain {
  FakeBrain(this.replies);

  final List<String> replies;
  final List<String> prompts = [];

  final List<String?> deltas = [];

  @override
  Future<String?> complete(String prompt, {String? delta}) async {
    prompts.add(prompt);
    deltas.add(delta);
    return replies.isEmpty ? '{"action":"say","text":"Fine."}' : replies.removeAt(0);
  }

  int resets = 0;

  @override
  String? lastError;

  @override
  Future<void> reset() async => resets++;
}

const whatsappScreen = ScreenState(package: 'com.whatsapp', nodes: [
  ScreenNode(id: 1, text: 'Laura', clickable: true),
  ScreenNode(id: 2, text: 'Arrivo tra dieci minuti', editable: true),
  ScreenNode(id: 3, desc: 'Invia', viewId: 'com.whatsapp:id/send', clickable: true),
]);

const gmailCompose = ScreenState(package: 'com.google.android.gm', nodes: [
  ScreenNode(id: 1, text: 'personale@gmail.com', viewId: 'com.google.android.gm:id/from_account_name', clickable: true),
  ScreenNode(id: 2, text: 'mario.rossi@lavoro.it', viewId: 'com.google.android.gm:id/to'),
  ScreenNode(id: 3, desc: 'Invia', viewId: 'com.google.android.gm:id/send', clickable: true),
]);

const contacts = [
  Contact(name: 'Mario Rossi', phones: ['333 1234567'], emails: ['mario.rossi@lavoro.it']),
  Contact(name: 'Mario Bianchi', phones: ['+39 340 7654321'], emails: ['mbianchi@gmail.com']),
  Contact(name: 'Laura Verdi', phones: ['347 1112223']),
];

const apps = [
  InstalledApp('WhatsApp', 'com.whatsapp'),
  InstalledApp('Gmail', 'com.google.android.gm'),
  InstalledApp('Tuttosport', 'it.tuttosport.app'),
  InstalledApp('Spotify', 'com.spotify.music'),
  InstalledApp('Intesa Sanpaolo Mobile', 'com.latuabancaperandroid'),
  InstalledApp('PayPal', 'com.paypal.android.p2pmobile'),
];

void main() {
  group('parseAction', () {
    test('JSON pulito', () {
      final a = parseAction('{"action":"open_app","app":"Tuttosport"}')!;
      expect(a.name, 'open_app');
      expect(a.str('app'), 'Tuttosport');
    });

    test('testo intorno e blocco ```json', () {
      final a = parseAction('Ecco:\n```json\n{"action": "tap", "id": 12}\n```')!;
      expect(a.name, 'tap');
      expect(a.integer('id'), 12);
    });

    test('sinonimi, apici singoli e chiavi senza virgolette', () {
      expect(parseAction("{action: 'click', text: 'Juventus'}")!.name, 'tap');
      expect(parseAction('{"action":"done","text":"Fatto"}')!.name, 'say');
      expect(parseAction('{"action":"open","name":"WhatsApp"}')!.str('app'), 'WhatsApp');
    });

    test('parametri annidati', () {
      final a = parseAction('{"action":"email","args":{"to":"Mario","body":"ciao"}}')!;
      expect(a.str('to'), 'Mario');
      expect(a.str('body'), 'ciao');
    });

    test('risposte inutilizzabili', () {
      expect(parseAction('Non so cosa fare'), isNull);
      expect(parseAction('{"action":"vola"}'), isNull);
    });
  });

  group('app', () {
    test('trova le app dal nome detto', () {
      expect(findApp(apps, 'tutto sport')!.package, 'it.tuttosport.app');
      expect(findApp(apps, 'whatsapp')!.package, 'com.whatsapp');
      expect(findApp(apps, 'la posta')?.package, isNull);
      expect(findApp(apps, 'posta')!.package, 'com.google.android.gm');
      expect(findApp(apps, 'Netflix'), isNull);
    });

    test('banche e pagamenti bloccati, le altre no', () {
      expect(isBlockedApp(label: 'Intesa Sanpaolo Mobile', package: 'com.latuabancaperandroid'), isTrue);
      expect(isBlockedApp(label: 'PayPal', package: 'com.paypal.android.p2pmobile'), isTrue);
      expect(isBlockedApp(label: 'Google Wallet', package: 'com.google.android.apps.walletnfcrel'), isTrue);
      expect(isBlockedApp(label: 'Satispay', package: 'com.satispay.customer'), isTrue);
      expect(isBlockedApp(label: 'Tuttosport', package: 'it.tuttosport.app'), isFalse);
      expect(isBlockedApp(label: 'Spotify', package: 'com.spotify.music'), isFalse);
      expect(isBlockedApp(label: 'WhatsApp', package: 'com.whatsapp'), isFalse);
      expect(isBlockedApp(label: 'Gmail', package: 'com.google.android.gm'), isFalse);
    });
  });

  group('contatti e risposte', () {
    test('sì / no', () {
      expect(parseYesNo('sì, mandala'), isTrue);
      expect(parseYesNo('Ok vai'), isTrue);
      expect(parseYesNo('no aspetta'), isFalse);
      expect(parseYesNo('annulla'), isFalse);
      expect(parseYesNo('boh'), isNull);
    });

    test('scelta tra opzioni', () {
      final opts = ['Mario Rossi', 'Mario Bianchi'];
      expect(pickOption(opts, 'Rossi'), 0);
      expect(pickOption(opts, 'il secondo'), 1);
      expect(pickOption(opts, 'Bianchi grazie'), 1);
      expect(pickOption(opts, 'Mario'), isNull);
    });

    test('numeri', () {
      expect(looksLikePhone('333 123 4567'), isTrue);
      expect(looksLikePhone('Marco'), isFalse);
      expect(internationalPhone('333 1234567'), '393331234567');
      expect(internationalPhone('+39 340 7654321'), '393407654321');
    });
  });

  test('lo schermo è descritto in modo compatto', () {
    final text = formatScreen(whatsappScreen);
    expect(text, contains('App in primo piano: com.whatsapp'));
    expect(text, contains('[3] Invia (tocca)'));
    expect(text, contains('(campo di testo)'));
  });

  test('il prompt contiene richiesta, passi e schermo', () {
    final p = buildStepPrompt(
      request: 'apri tuttosport',
      history: const [StepRecord('open_app', 'Aperta Tuttosport.')],
      screen: 'SCHERMO',
      now: DateTime(2026, 10, 24, 11, 30),
    );
    expect(p, contains('"apri tuttosport"'));
    expect(p, contains('1. open_app → Aperta Tuttosport.'));
    expect(p, contains('SCHERMO'));
    expect(p, contains('sabato 24/10/2026 ore 11:30'));
  });

  group('comandi rapidi', () {
    test('chiamate, messaggi, app', () {
      expect(parseQuick('chiama Marco')!.action.str('contact'), 'Marco');
      expect(parseQuick('Chiama la mamma')!.action.str('contact'), 'mamma');
      final wa = parseQuick('scrivi a Laura su WhatsApp che arrivo tra dieci minuti')!.action;
      expect(wa.name, 'whatsapp');
      expect(wa.str('contact'), 'Laura');
      expect(wa.str('text'), 'Arrivo tra dieci minuti');
      final wa2 = parseQuick('manda un messaggio a Laura su whatsapp che arrivo')!.action;
      expect(wa2.name, 'whatsapp');
      expect(wa2.str('contact'), 'Laura');
      final sms = parseQuick('manda un sms a Paolo che sono in ritardo')!.action;
      expect(sms.name, 'sms');
      expect(sms.str('text'), 'Sono in ritardo');
      expect(parseQuick("Apri l'app di Spotify")!.action.str('app'), 'Spotify');
      final open = parseQuick('apri tuttosport e dimmi cosa sta facendo la Juve e chi ha segnato')!;
      expect(open.action.str('app'), 'tuttosport');
      expect(open.followUp, 'dimmi cosa sta facendo la Juve e chi ha segnato');
      expect(parseQuick('torna indietro')!.action.name, 'back');
      expect(parseQuick('cerca ristoranti vicino a me')!.action.str('query'), 'ristoranti vicino a me');
    });

    test('quelli complessi vanno al modello', () {
      expect(parseQuick('manda una mail a Mario dal mio account di lavoro'), isNull);
      expect(parseQuick('scrivi a Laura che arrivo'), isNull);
      expect(parseQuick('cosa sta facendo la Juve?'), isNull);
    });

    test('ore e durate', () {
      expect(parseTime('7 e mezza'), (7, 30));
      expect(parseTime('sette'), (7, 0));
      expect(parseTime('6:45'), (6, 45));
      expect(parseTime('otto meno un quarto'), (7, 45));
      expect(parseTime('sette e venticinque'), (7, 25));
      expect(parseTime('9 di sera'), (21, 0));
      expect(parseTime('mezzogiorno'), (12, 0));
      expect(parseQuick('mettimi la sveglia alle sette e un quarto')!.action.integer('minute'), 15);
      expect(parseDuration('10 minuti'), 600);
      expect(parseDuration('dieci minuti'), 600);
      expect(parseDuration("un'ora"), 3600);
      expect(parseDuration('un minuto e mezzo'), 90);
      expect(parseQuick('metti un timer di 5 minuti')!.action.integer('seconds'), 300);
    });
  });

  group('agente', () {
    test('mail: due Mario → chiede quale, sceglie l\'account, conferma e invia', () async {
      final phone = FakePhone(contacts: contacts, installed: apps);
      final voice = FakeVoice(['Rossi', 'sì']);
      final brain = FakeBrain([
        '{"action":"email","to":"Mario","subject":"Riunione","body":"La riunione è spostata a lunedì.","account":"lavoro"}',
      ]);
      // Nella schermata di Gmail il menu account mostra l'account di lavoro.
      final agent = Agent(phone: _GmailWithAccounts(phone), voice: voice, brain: brain);
      final out = await agent.run('manda una mail a Mario dal mio account di lavoro');
      expect(voice.said.first, contains('Mario Rossi'));
      expect(voice.said.first, contains('Mario Bianchi'));
      expect(phone.calls, contains('email mario.rossi@lavoro.it | Riunione | La riunione è spostata a lunedì.'));
      expect(phone.calls, contains('tap dom.lavoro@azienda.it'));
      expect(phone.calls.last, 'tap Invia');
      expect(out, 'Mail inviata a Mario Rossi.');
    });

    test('mail: se l\'utente dice no non invia niente', () async {
      final phone = FakePhone(contacts: contacts, installed: apps);
      final voice = FakeVoice(['no lascia stare']);
      final brain = FakeBrain(['{"action":"email","to":"Laura Verdi","body":"ciao"}']);
      final out = await Agent(phone: phone, voice: voice, brain: brain).run('scrivi a Laura');
      // Laura non ha email: chiede l'indirizzo, l'utente non lo dà.
      expect(phone.calls.where((c) => c.startsWith('email')), isEmpty);
      expect(out, isNotEmpty);
    });

    test('WhatsApp: conferma e preme Invia', () async {
      final phone = FakePhone(contacts: contacts, installed: apps);
      final voice = FakeVoice(['sì']);
      final brain = FakeBrain(['{"action":"whatsapp","contact":"Laura","text":"Arrivo tra dieci minuti"}']);
      final out = await Agent(phone: phone, voice: voice, brain: brain).run('scrivi a Laura su whatsapp che arrivo tra dieci minuti');
      expect(phone.calls, contains('whatsapp 393471112223 Arrivo tra dieci minuti'));
      expect(phone.calls.last, 'tap Invia');
      expect(out, contains('inviato a Laura Verdi'));
    });

    test('chiamata annullata con un no', () async {
      final phone = FakePhone(contacts: contacts, installed: apps);
      final voice = FakeVoice(['no']);
      final brain = FakeBrain(['{"action":"call","contact":"Laura"}']);
      final out = await Agent(phone: phone, voice: voice, brain: brain).run('chiama Laura');
      expect(phone.calls.where((c) => c.startsWith('call')), isEmpty);
      expect(out, 'Ok, non chiamo.');
    });

    test('Tuttosport: apre l\'app, legge lo schermo e riassume', () async {
      final phone = FakePhone(installed: apps);
      phone.screens['it.tuttosport.app'] = const ScreenState(package: 'it.tuttosport.app', nodes: [
        ScreenNode(id: 1, text: 'Juventus 2 - 1 Milan', clickable: true),
        ScreenNode(id: 2, text: "Gol: Vlahović 23', Yildiz 67'"),
      ]);
      final voice = FakeVoice([]);
      final brain = FakeBrain([
        '{"action":"open_app","app":"tutto sport"}',
        '{"action":"say","text":"La Juve vince 2 a 1 col Milan, gol di Vlahović e Yildiz."}',
      ]);
      final out = await Agent(phone: phone, voice: voice, brain: brain).run('cosa sta facendo la Juve?');
      expect(phone.calls.first, 'openApp it.tuttosport.app');
      // Il secondo passo manda al modello solo la parte nuova, con lo schermo.
      expect(brain.prompts[1], contains('Juventus 2 - 1 Milan'));
      expect(brain.deltas[0], isNull);
      expect(brain.deltas[1], contains('Juventus 2 - 1 Milan'));
      expect(brain.deltas[1], isNot(contains('Azioni:')));
      expect(brain.resets, 1);
      expect(out, contains('Vlahović'));
    });

    test('comando rapido: apre l\'app senza il modello, poi una sola domanda', () async {
      final phone = FakePhone(installed: apps);
      phone.screens['it.tuttosport.app'] = const ScreenState(package: 'it.tuttosport.app', nodes: [
        ScreenNode(id: 1, text: 'Juventus 2 - 1 Milan', clickable: true),
        ScreenNode(id: 2, text: 'Gol di Vlahović e Yildiz'),
        ScreenNode(id: 3, text: 'Classifica'),
      ]);
      final voice = FakeVoice([]);
      final brain = FakeBrain(['{"action":"say","text":"Juve avanti 2 a 1."}']);
      final out = await Agent(phone: phone, voice: voice, brain: brain)
          .run('apri tuttosport e dimmi cosa sta facendo la Juve');
      expect(phone.calls.first, 'openApp it.tuttosport.app');
      expect(brain.prompts, hasLength(1));
      expect(brain.prompts.first, contains('Juventus 2 - 1 Milan'));
      expect(out, 'Juve avanti 2 a 1.');
    });

    test('comando rapido senza modello: sveglia', () async {
      final phone = FakePhone(installed: apps);
      final voice = FakeVoice([]);
      final brain = FakeBrain([]);
      final out = await Agent(phone: phone, voice: voice, brain: brain).run('sveglia alle 7 e mezza');
      expect(phone.calls, ['alarm 7:30']);
      expect(brain.prompts, isEmpty);
      expect(out, contains('7:30'));
    });

    test('non apre le app della banca', () async {
      final phone = FakePhone(installed: apps);
      final voice = FakeVoice([]);
      final brain = FakeBrain(['{"action":"open_app","app":"Intesa Sanpaolo"}']);
      final out = await Agent(phone: phone, voice: voice, brain: brain).run('apri la banca');
      expect(phone.calls, isEmpty);
      expect(out, contains('non la apro'));
    });

    test('un tocco su Invia fatto dal modello chiede conferma', () async {
      final phone = FakePhone(installed: apps)..current = whatsappScreen;
      final voice = FakeVoice(['no']);
      final brain = FakeBrain(['{"action":"tap","id":3}']);
      await Agent(phone: phone, voice: voice, brain: brain).run('premi invia');
      expect(phone.calls, isEmpty);
    });

    test('risposte non valide: dopo tre si arrende con gentilezza', () async {
      final phone = FakePhone(installed: apps);
      final voice = FakeVoice([]);
      final brain = FakeBrain(['boh', 'mah', 'uff']);
      final out = await Agent(phone: phone, voice: voice, brain: brain).run('fai qualcosa');
      expect(out, contains('non ho capito'));
    });

    test('domanda all\'utente e risposta passata al modello', () async {
      final phone = FakePhone(installed: apps);
      final voice = FakeVoice(['alle sette e mezza']);
      final brain = FakeBrain([
        '{"action":"ask","question":"A che ora?"}',
        '{"action":"alarm","hour":7,"minute":30}',
        '{"action":"say","text":"Sveglia alle 7 e 30."}',
      ]);
      await Agent(phone: phone, voice: voice, brain: brain).run('mettimi una sveglia');
      expect(brain.prompts[1], contains('alle sette e mezza'));
      expect(phone.calls, contains('alarm 7:30'));
    });
  });
}

/// Gmail con il menu degli account: toccando il mittente compare la lista.
class _GmailWithAccounts extends FakePhone {
  _GmailWithAccounts(this.inner) : super(contacts: inner.contacts, installed: inner.installed);

  final FakePhone inner;

  @override
  List<String> get calls => inner.calls;

  @override
  Future<bool> composeEmail(String to, String subject, String body) => inner.composeEmail(to, subject, body);

  @override
  Future<ScreenState> screen() async => inner.current;

  @override
  Future<List<Contact>> findContacts(String query) => inner.findContacts(query);

  @override
  Future<bool> tap(int id) async {
    final ok = await inner.tap(id);
    final n = inner.current.byId(id);
    if (inner.current.package == 'com.google.android.gm' && n?.shortViewId == 'from_account_name') {
      inner.current = const ScreenState(package: 'com.google.android.gm', nodes: [
        ScreenNode(id: 10, text: 'personale@gmail.com', clickable: true),
        ScreenNode(id: 11, text: 'dom.lavoro@azienda.it', clickable: true),
      ]);
    } else if (n?.id == 11) {
      inner.current = gmailCompose;
    }
    return ok;
  }
}
