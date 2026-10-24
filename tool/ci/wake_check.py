"""Verifica "Ciao Dom" con il vero modello Vosk e voci sintetiche (CI).

Scarica il modello italiano, legge da VoskModel.kt le varianti di "Dom",
genera frasi con espeak-ng e controlla che la grammatica riconosca
l'attivazione e ignori le frasi normali. Stampa un riepilogo.
"""
import json, os, re, subprocess, sys, urllib.request, zipfile, wave

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
kt = open(os.path.join(ROOT, "tool/android/VoskModel.kt")).read()
variants = re.findall(r'"(\w+)"', re.search(r"DOM_VARIANTS = listOf\((.*?)\)", kt).group(1))
url = re.search(r'URL_IT = "(.*?)"', kt).group(1)
name = re.search(r'DIR = "(.*?)"', kt).group(1)

work = os.path.join(ROOT, "build", "wake")
os.makedirs(work, exist_ok=True)
model_dir = os.path.join(work, name)
if not os.path.isdir(model_dir):
    z = os.path.join(work, "m.zip")
    urllib.request.urlretrieve(url, z)
    zipfile.ZipFile(z).extractall(work)

import vosk
vosk.SetLogLevel(-1)
model = vosk.Model(model_dir)

words_file = None
for cand in ["graph/words.txt", "words.txt"]:
    p = os.path.join(model_dir, cand)
    if os.path.exists(p):
        words_file = p
known = None
if words_file:
    known = {l.split()[0] for l in open(words_file, encoding="utf-8") if l.strip()}
present = [v for v in variants if known is None or v in known]
print("words.txt:", words_file, "| varianti nel vocabolario:", present, "| mancanti:", [v for v in variants if v not in present])
print("ciao nel vocabolario:", None if known is None else ("ciao" in known))

grammar = json.dumps([f"ciao {v}" for v in (present or variants)] + ["ciao", "[unk]"], ensure_ascii=False)
wake_re = re.compile(r"\bciao\s+(" + "|".join(variants) + r")\b")

def wav(text, voice, speed):
    out = os.path.join(work, re.sub(r"\W+", "_", f"{text}_{voice}_{speed}") + ".wav")
    raw = out + ".raw.wav"
    subprocess.run(["espeak-ng", "-v", voice, "-s", str(speed), "-w", raw, text], check=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", raw, "-ar", "16000", "-ac", "1", out], check=True)
    return out

def recognize(path, grammar=None):
    wf = wave.open(path, "rb")
    rec = vosk.KaldiRecognizer(model, wf.getframerate(), grammar) if grammar else vosk.KaldiRecognizer(model, wf.getframerate())
    texts = []
    while True:
        data = wf.readframes(4000)
        if not data:
            break
        if rec.AcceptWaveform(data):
            texts.append(json.loads(rec.Result())["text"])
        else:
            p = json.loads(rec.PartialResult())["partial"]
            if grammar and wake_re.search(p):
                texts.append(p)
    texts.append(json.loads(rec.FinalResult())["text"])
    return " | ".join(t for t in texts if t)

use_grammar = re.search(r"WAKE_USE_GRAMMAR = (true|false)", kt).group(1) == "true"
print("grammatica:", use_grammar)
wake_phrases = ["ciao dom", "ciao dom!", "ciao, dom", "ehi ciao dom"]
other = ["buongiorno a tutti", "chiama marco", "ciao come stai", "domani piove", "ciao mamma",
         "ciao tommaso", "ciao domenico", "apri tuttosport", "ciao a tutti", "dove sono le chiavi"]
ok_wake = 0
total_wake = 0
false_pos = 0
lines = []
for voice in ["it", "it+m3", "it+f2"]:
    for speed in [140, 175]:
        for ph in wake_phrases:
            f = wav(ph, voice, speed)
            g = recognize(f, grammar)
            free = recognize(f)
            hit = bool(wake_re.search(g if use_grammar else free))
            total_wake += 1
            ok_wake += hit
            lines.append(f"WAKE {voice}/{speed} '{ph}': grammatica='{g}' libero='{free}' -> {'OK' if hit else 'MANCATO'}")
        for ph in other:
            f = wav(ph, voice, speed)
            g = recognize(f, grammar) if use_grammar else recognize(f)
            hit = bool(wake_re.search(g))
            false_pos += hit
            if hit:
                lines.append(f"FALSO {voice}/{speed} '{ph}': '{g}'")
print("\n".join(lines))
summary = f"[{'grammatica' if use_grammar else 'libero'}] Ciao Dom riconosciuto {ok_wake}/{total_wake} (voci sintetiche), falsi allarmi {false_pos}/{len(other)*6}, varianti nel vocabolario: {present}"
print(summary)
with open(os.path.join(work, "summary.txt"), "w") as fh:
    fh.write(summary + "\n" + "\n".join(lines[:12]))
