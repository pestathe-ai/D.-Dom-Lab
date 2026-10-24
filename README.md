# D. Dom Lab

**Dom** è un assistente vocale per Android che comanda il telefono al posto tuo:
gli parli, lui apre le app, legge lo schermo, tocca, scrive, manda messaggi e mail.
Pensato per usare il telefono senza mani, anche in auto.

Il "cervello" è **Gemini** (piano gratuito di Google, con la tua chiave di AI Studio): il telefono
resta leggero. Le azioni (aprire app, toccare, scrivere, leggere lo schermo) restano sul telefono,
e i comandi più comuni non passano proprio da internet.

## Novità v0.3

- **Gemini al posto di Gemma**: niente modello da 2,6 GB in memoria, niente rallentamenti.
  Modello "Veloce" (Gemini 3.5 Flash-Lite) o "Sveglio" (Gemini 3.8 Flash); se finiscono le
  richieste gratuite passa da solo a Gemini 3.6 Flash.
- **Niente lavoro in background**: l'app non controlla più lo stato di continuo, la voce offline
  si carica solo se serve, l'accessibilità segue solo i cambi di schermata.
- **"Ciao Dom" spento di serie** (si accende dalla configurazione).
- **Comandi rapidi sul telefono**: chiama, apri, SMS, WhatsApp, sveglia, timer, cerca, indietro
  funzionano anche senza internet.

## Privacy

Su internet va solo il testo del comando e il testo dello schermo dell'app su cui Dom sta lavorando.
Rubrica, foto, file, voce e immagini dello schermo restano sul telefono. Le app di banche e pagamenti
non vengono mai lette. In Europa (SEE, Svizzera, Regno Unito) Google non usa questi testi per
migliorare i suoi prodotti, anche con il piano gratuito.

## Cosa sa fare

- **"Ciao Dom"**: attivazione a voce, offline (si accende dalla configurazione).
- **Bolla microfono** sopra le altre app e pulsante nell'app.
- **Aprire app** per nome detto a voce ("apri Tuttosport").
- **Leggere e riassumere lo schermo**: "Apri Tuttosport e dimmi cosa sta facendo la Juve e chi ha segnato".
- **Toccare, scrivere, scorrere, indietro, home** in qualsiasi app (servizio di accessibilità).
- **Chiamate, SMS, WhatsApp, mail** con scelta del contatto dalla rubrica e dell'account Gmail.
- **Sveglie, timer, ricerche web, pagine, pannelli delle impostazioni** (Wi-Fi, Bluetooth, volume…).
- **Fa domande** quando manca qualcosa ("Ho trovato due Mario, quale?") o quando si blocca.
- **Chiede sempre conferma** prima di inviare, chiamare o premere pulsanti come Invia/Paga/Elimina.
- **Non tocca** app di banche, pagamenti e password.

## Configurazione (una volta)

1. Incolla la chiave gratuita di Google AI Studio (aistudio.google.com/apikey, piano "Free").
2. Concedi i permessi (microfono, rubrica, telefono, SMS).
3. Attiva l'accessibilità: Impostazioni → Accessibilità → "Dom, assistente vocale".
4. Su Honor/MagicOS togli l'ottimizzazione batteria.
5. Facoltativo: voce offline (48 MB), "Ciao Dom", bolla microfono.

## Limiti da sapere

- Serve internet per i compiti "intelligenti" (leggere app, mail, richieste libere).
- Il piano gratuito di Gemini ha un limite di richieste al giorno, condiviso tra le app che usano
  la stessa chiave/progetto.
- Non sblocca il telefono protetto da PIN/impronta.
- "Ciao Dom", se acceso, tiene il microfono attivo (icona di Android nella barra, un po' di batteria).
- Le interfacce delle app cambiano: se Dom non trova un pulsante te lo dice e chiede.

## Struttura

- `lib/core/` logica pura e testata: azioni JSON, prompt, lettura schermo, app, contatti, agente.
- `lib/services/` Gemini e ponte verso Android.
- `tool/android/` codice Kotlin: accessibilità e bolla, "Ciao Dom" (Vosk), voce, telefono.
- La cartella `android/` viene generata in CI da `tool/setup_platforms.sh`.
