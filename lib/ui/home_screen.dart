import 'package:material_ui/material_ui.dart';

import '../core/agent.dart';
import '../core/gemini_api.dart';
import '../services/native.dart';
import '../state/app_state.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  bool _showSetup = false;
  int _lastLog = 0;

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    if (s.log.length != _lastLog) {
      _lastLog = s.log.length;
      _scrollDown();
    }
    final setup = !s.setupDone || _showSetup;
    return Scaffold(
      appBar: AppBar(
        title: const Text('D. Dom Lab', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (s.log.isNotEmpty)
            IconButton(tooltip: 'Cancella conversazione', onPressed: s.clearLog, icon: const Icon(Icons.delete_sweep_outlined)),
          IconButton(
            tooltip: 'Impostazioni',
            onPressed: () => setState(() => _showSetup = !_showSetup),
            icon: Icon(_showSetup ? Icons.close : Icons.tune),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (setup) Flexible(flex: s.log.isEmpty ? 10 : 6, child: const _SetupPanel()),
            Expanded(
              flex: 10,
              child: s.log.isEmpty
                  ? _Empty(phase: s.phase, ready: s.setupDone, wake: s.status.wake)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: s.log.length,
                      itemBuilder: (_, i) => _Bubble(entry: s.log[i]),
                    ),
            ),
            _PhaseBar(phase: s.phase, busy: s.busy, onStop: s.stop),
            _InputBar(
              controller: _text,
              busy: s.busy,
              onSend: () {
                final t = _text.text;
                _text.clear();
                FocusScope.of(context).unfocus();
                s.runTyped(t);
              },
              onMic: () => s.activate(),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.phase, required this.ready, required this.wake});

  final Phase phase;
  final bool ready;
  final bool wake;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.record_voice_over_outlined, size: 56, color: cs.primary),
            const SizedBox(height: 12),
            Text(
              ready ? (wake ? 'Di\' "Ciao Dom" oppure tocca il microfono' : 'Tocca il microfono e parla') : 'Completa la configurazione qui sopra',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Esempi: "Apri Tuttosport e dimmi cosa sta facendo la Juve", '
              '"Manda una mail a Mario dal mio account di lavoro", '
              '"Scrivi a Laura su WhatsApp che arrivo tra dieci minuti", '
              '"Sveglia alle 7 e mezza".',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (entry.kind) {
      case 'step':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Icon(Icons.bolt, size: 14, color: cs.tertiary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(entry.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant, fontFamily: 'monospace')),
              ),
            ],
          ),
        );
      case 'error':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(entry.text, style: TextStyle(color: cs.error)),
        );
    }
    final mine = entry.kind == 'user';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        decoration: BoxDecoration(
          color: mine ? cs.primary : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 4),
            bottomRight: Radius.circular(mine ? 4 : 18),
          ),
        ),
        child: Text(entry.text, style: TextStyle(color: mine ? cs.onPrimary : cs.onSurface)),
      ),
    );
  }
}

class _PhaseBar extends StatelessWidget {
  const _PhaseBar({required this.phase, required this.busy, required this.onStop});

  final Phase phase;
  final bool busy;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    if (!busy && phase == Phase.idle) return const SizedBox.shrink();
    final label = switch (phase) {
      Phase.listening => 'Ti ascolto…',
      Phase.thinking => 'Ci penso…',
      Phase.speaking => 'Sto parlando…',
      Phase.idle => 'Al lavoro…',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Row(
        children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
          TextButton.icon(onPressed: onStop, icon: const Icon(Icons.stop_circle_outlined), label: const Text('Ferma')),
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({required this.controller, required this.busy, required this.onSend, required this.onMic});

  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onMic;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              enabled: !busy,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => onSend(),
              decoration: InputDecoration(
                hintText: 'Scrivi un comando…',
                filled: true,
                fillColor: cs.surfaceContainerHighest,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                suffixIcon: IconButton(onPressed: busy ? null : onSend, icon: const Icon(Icons.send)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 64,
            height: 64,
            child: FloatingActionButton(
              heroTag: 'mic',
              onPressed: busy ? null : onMic,
              backgroundColor: busy ? cs.surfaceContainerHighest : cs.tertiary,
              foregroundColor: Colors.white,
              shape: const CircleBorder(),
              child: const Icon(Icons.mic, size: 30),
            ),
          ),
        ],
      ),
    );
  }
}

/// Configurazione: modello, permessi, accessibilità, batteria, "Ciao Dom".
class _SetupPanel extends StatelessWidget {
  const _SetupPanel();

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final st = s.status;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      children: [
        Text('Configurazione', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const _KeyStep(),
        _Step(
          done: st.permissions,
          title: '2. Permessi',
          subtitle: 'Microfono, rubrica, telefono e SMS',
          action: st.permissions
              ? null
              : FilledButton.tonal(
                  onPressed: () async {
                    final ok = await NativeControls.requestPermissions();
                    if (!ok) await NativeControls.openAppSettings();
                    await s.refreshStatus();
                  },
                  child: const Text('Concedi')),
        ),
        _Step(
          done: st.a11y,
          title: '3. Accessibilità',
          subtitle: st.a11y
              ? 'Attiva: Dom può leggere lo schermo e toccare al posto tuo'
              : 'Impostazioni → Accessibilità → App installate → "Dom, assistente vocale" → Attiva',
          action: st.a11y ? null : FilledButton.tonal(onPressed: NativeControls.openA11ySettings, child: const Text('Apri')),
        ),
        _Step(
          done: st.battery,
          title: '4. Batteria (MagicOS)',
          subtitle: st.battery
              ? 'Dom non viene chiuso in background'
              : 'Consenti a Dom di restare attivo, altrimenti MagicOS lo chiude. Su Honor anche: Batteria → Avvio app → D. Dom Lab → Gestisci manualmente (tutto attivo)',
          action: st.battery ? null : FilledButton.tonal(onPressed: NativeControls.openBatterySettings, child: const Text('Apri')),
        ),
        _Step(
          done: st.vosk == 'ready' || st.vosk == 'downloaded',
          title: 'Facoltativo · Voce offline',
          subtitle: _voskText(st),
          action: st.vosk == 'missing' || st.vosk.startsWith('error')
              ? FilledButton.tonal(onPressed: NativeControls.downloadVosk, child: const Text('Scarica'))
              : null,
          progress: st.vosk.startsWith('downloading') ? (int.tryParse(st.vosk.split(' ').last) ?? 0) / 100 : null,
        ),
        const Divider(height: 20),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: st.wake,
          onChanged: s.setWake,
          title: const Text('Attivazione con "Ciao Dom"'),
          subtitle: Text(_wakeText(st)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: st.bubble,
          onChanged: st.a11y ? s.setBubble : null,
          title: const Text('Bolla microfono sopra le altre app'),
          subtitle: const Text('Un tocco per parlare con Dom da qualsiasi schermata; trascinala dove vuoi.'),
        ),
      ],
    );
  }

  static String _voskText(NativeStatus st) {
    final v = st.vosk;
    final engine = switch (st.engine) {
      'system-offline' => 'riconoscitore di sistema, offline',
      'system' => 'riconoscitore di sistema',
      'google' => 'riconoscitore Google',
      'vosk' => 'voce offline di Dom',
      _ => '',
    };
    final using = engine.isEmpty ? '' : ' Ultimo comando capito con: $engine.';
    if (v.startsWith('downloading')) return 'Scarico la voce offline… ${v.split(' ').last}%';
    if (v == 'loading') return 'Preparo la voce offline…';
    if (v.startsWith('error')) return 'Problema: ${v.substring(5).trim()}. Riprova.';
    if (v == 'missing') {
      return 'Serve per "Ciao Dom" e se il riconoscimento di sistema non funziona. 48 MB, una volta sola.${st.recognizer ? '' : ' Su questo telefono il riconoscimento di sistema non c\'è: è indispensabile.'}';
    }
    return 'Pronta, funziona senza internet.$using';
  }

  static String _wakeText(NativeStatus st) {
    if (!st.wake) {
      return 'Dom ascolta solo la frase "Ciao Dom", sul telefono e senza internet. La prima volta scarica 48 MB.';
    }
    final w = st.wakeStatus;
    if (w.startsWith('downloading')) return 'Scarico il riconoscitore della frase… ${w.split(' ').last}%';
    if (w == 'loading') return 'Preparo il riconoscitore…';
    if (w == 'listening') {
      return st.lastHeard.isEmpty ? 'In ascolto: di\' "Ciao Dom".' : 'In ascolto: di\' "Ciao Dom". Ultima cosa sentita: "${st.lastHeard}".';
    }
    if (w == 'paused' || w == 'session') return 'In pausa mentre Dom lavora.';
    if (w.startsWith('error')) return 'Problema: ${w.substring(5).trim()}. Spegni e riaccendi.';
    return 'Avvio…';
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.done, required this.title, required this.subtitle, this.action, this.error, this.progress});

  final bool done;
  final String title;
  final String subtitle;
  final Widget? action;
  final String? error;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(done ? Icons.check_circle : Icons.radio_button_unchecked, color: done ? Colors.green : cs.outline),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                if (progress != null)
                  Padding(padding: const EdgeInsets.only(top: 6), child: LinearProgressIndicator(value: progress)),
                if (error != null && !done)
                  Text(error!, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.error, fontSize: 12)),
              ],
            ),
          ),
          if (action != null) ...[const SizedBox(width: 8), action!],
        ],
      ),
    );
  }
}

/// Passo 1: la chiave gratuita di Gemini e la scelta del modello.
class _KeyStep extends StatefulWidget {
  const _KeyStep();

  @override
  State<_KeyStep> createState() => _KeyStepState();
}

class _KeyStepState extends State<_KeyStep> {
  final _ctrl = TextEditingController();
  bool _editing = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final editing = _editing || !s.hasKey;
    String subtitle;
    if (!s.hasKey) {
      subtitle = 'Incolla la tua chiave gratuita di Google AI Studio (aistudio.google.com/apikey). Resta solo su questo telefono.';
    } else if (s.checkingKey) {
      subtitle = 'Provo la chiave…';
    } else if (s.keyCheck == null) {
      subtitle = 'Chiave salvata (…${_tail(s.apiKey)}).';
    } else if (s.keyCheck!.isEmpty) {
      subtitle = 'Chiave funzionante (…${_tail(s.apiKey)}).';
    } else {
      subtitle = s.keyCheck!;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Step(
            done: s.hasKey && s.keyCheck != null && s.keyCheck!.isEmpty,
            title: '1. Cervello: Gemini',
            subtitle: subtitle,
            action: editing
                ? null
                : PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (v) {
                      if (v == 'edit') setState(() => _editing = true);
                      if (v == 'test') s.testKey();
                      if (v == 'remove') s.setKey('');
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Cambia chiave')),
                      PopupMenuItem(value: 'test', child: Text('Prova chiave')),
                      PopupMenuItem(value: 'remove', child: Text('Cancella chiave')),
                    ],
                  ),
          ),
          if (editing)
            Padding(
              padding: const EdgeInsets.only(left: 36, top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(isDense: true, hintText: 'Chiave API (AIza…)', border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () async {
                      final k = _ctrl.text.trim();
                      if (k.isEmpty) return;
                      _ctrl.clear();
                      setState(() => _editing = false);
                      FocusScope.of(context).unfocus();
                      await s.setKey(k);
                    },
                    child: const Text('Salva'),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 36, top: 8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final m in geminiModels)
                  ChoiceChip(
                    label: Text(m.label),
                    selected: s.modelId == m.id,
                    onSelected: (_) => s.setModel(m.id),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 36, top: 2),
            child: Text(s.model.description, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ),
        ],
      ),
    );
  }

  static String _tail(String k) => k.length <= 4 ? k : k.substring(k.length - 4);
}
