# D. Dom Lab

**Dom** è un assistente vocale per Android che comanda il telefono al posto tuo:
gli parli, lui apre le app, legge lo schermo, tocca, scrive, manda messaggi e mail.
Pensato per usare il telefono senza mani, anche in auto.

Tutto gira **sul telefono, gratis e senza cloud**: il "cervello" è Gemma 4 E2B di Google
(lo stesso modello di D. Paper Lab) sulla GPU con LiteRT-LM; l'attivazione "Ciao Dom"
usa Vosk, offline.

## Novità v0.2

- **Più veloce**: i comandi comuni (chiama, apri, SMS, WhatsApp, sveglia, timer, cerca, indietro)
  partono subito senza Gemma; Gemma resta caricata, ricorda il compito tra un passo e l'altro
  e si ferma appena ha deciso. Nel registro si vede quanto ci mette ogni passo.
- **Riconoscimento vocale affidabile**: prova il riconoscitore di sistema, poi quello di Google,
  poi la voce offline di Dom (Vosk). Se qualcosa non va, l'errore compare nella conversazione.
- **Bip** quando il microfono si apre.
- **"Ciao Dom" più tollerante** e, se l'app è già aperta, risponde senza cambiare schermata.
- Nuovo passo di configurazione **"Voce offline"** (48 MB).

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

1. Scarica il modello (2,6 GB, meglio col Wi-Fi).
2. Concedi i permessi (microfono, rubrica, telefono, SMS).
3. Attiva l'accessibilità: Impostazioni → Accessibilità → "Dom, assistente vocale".
4. Su Honor/MagicOS togli l'ottimizzazione batteria e metti "Avvio app" in gestione manuale.
5. Scarica la voce offline (48 MB).
6. Facoltativo: accendi "Ciao Dom" e la bolla.

## Limiti da sapere

- Gemma in locale è meno brillante dei modelli in cloud: comandi chiari e brevi funzionano meglio.
  Ogni passo richiede qualche secondo di calcolo.
- Il modello va riscaricato anche se è già in D. Paper Lab (ogni app ha il suo spazio privato).
- Non sblocca il telefono protetto da PIN/impronta.
- Il riconoscimento del comando usa quello di sistema di Android: offline se il pacchetto
  italiano è scaricato, altrimenti usa internet.
- "Ciao Dom" tiene il microfono acceso: consuma un po' di batteria e mostra una notifica fissa.
- Le interfacce delle app cambiano: se Dom non trova un pulsante te lo dice e chiede.

## Struttura

- `lib/core/` logica pura e testata: azioni JSON, prompt, lettura schermo, app, contatti, agente.
- `lib/services/` Gemma sul telefono e ponte verso Android.
- `tool/android/` codice Kotlin: accessibilità e bolla, "Ciao Dom" (Vosk), voce, telefono.
- La cartella `android/` viene generata in CI da `tool/setup_platforms.sh`.
