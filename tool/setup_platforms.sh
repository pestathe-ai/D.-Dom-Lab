#!/usr/bin/env bash
# Genera la cartella android/ (non salvata nel repository) e la configura:
# permessi, servizio di accessibilità, servizio "Ciao Dom", Vosk.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter create --project-name dom_lab --org dev.domlab --platforms=android .
rm -f test/widget_test.dart

MANIFEST=android/app/src/main/AndroidManifest.xml
sed -i 's#android:label="dom_lab"#android:label="D. Dom Lab"#' "$MANIFEST"

# Icona (casa Dom Studio con microfono), testi e configurazione accessibilità.
cp -r tool/android/res/. android/app/src/main/res/

# Codice nativo.
KT=android/app/src/main/kotlin/dev/domlab/dom_lab
find android/app/src/main -name 'MainActivity.*' -delete
mkdir -p "$KT"
cp tool/android/*.kt "$KT/"

python3 - "$MANIFEST" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()

perms = [
    'android.permission.INTERNET',
    'android.permission.RECORD_AUDIO',
    'android.permission.READ_CONTACTS',
    'android.permission.CALL_PHONE',
    'android.permission.SEND_SMS',
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_MICROPHONE',
    'android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS',
    'com.android.alarm.permission.SET_ALARM',
    'android.permission.QUERY_ALL_PACKAGES',
]
block = ''.join(f'    <uses-permission android:name="{x}"/>\n' for x in perms if x not in s)
queries = '''    <queries>
        <intent><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent>
        <intent><action android:name="android.speech.RecognitionService"/></intent>
        <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>
        <intent><action android:name="android.intent.action.SENDTO"/><data android:scheme="mailto"/></intent>
        <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="https"/></intent>
        <package android:name="com.whatsapp"/>
        <package android:name="com.whatsapp.w4b"/>
        <package android:name="com.google.android.gm"/>
    </queries>
'''
i = s.index('<application')
s = s[:i] + block + queries + '    ' + s[i:]

# L'attività si apre anche come "assistente" (ASSIST) e in un'unica istanza.
assist = '''
            <intent-filter>
                <action android:name="android.intent.action.ASSIST"/>
                <category android:name="android.intent.category.DEFAULT"/>
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.VOICE_COMMAND"/>
                <category android:name="android.intent.category.DEFAULT"/>
            </intent-filter>
'''
i = s.index('</activity>')
s = s[:i] + assist + '        ' + s[i:]
s = s.replace('android:launchMode="singleTop"', 'android:launchMode="singleTask"')

services = '''
        <service
            android:name=".DomA11yService"
            android:exported="false"
            android:label="@string/a11y_service_name"
            android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
            <intent-filter>
                <action android:name="android.accessibilityservice.AccessibilityService"/>
            </intent-filter>
            <meta-data
                android:name="android.accessibilityservice"
                android:resource="@xml/dom_accessibility"/>
        </service>
        <service
            android:name=".WakeWordService"
            android:exported="false"
            android:foregroundServiceType="microphone"/>
'''
i = s.rindex('</application>')
s = s[:i] + services + '    ' + s[i:]
open(p, 'w').write(s)
PY
grep -q 'DomA11yService' "$MANIFEST" || { cat "$MANIFEST"; exit 1; }
grep -q 'android.intent.action.ASSIST' "$MANIFEST" || { cat "$MANIFEST"; exit 1; }

for G in android/app/build.gradle.kts android/app/build.gradle; do
  if [ -f "$G" ]; then
    # Riconoscimento vocale moderno e servizi in primo piano col microfono: Android 11+.
    sed -i -E 's/minSdk( =|) flutter\.minSdkVersion/minSdk\1 30/' "$G"
    grep -q 'minSdk = 30\|minSdk 30' "$G" || { echo "minSdk non impostato"; cat "$G"; exit 1; }
    # Niente R8: rinomina classi usate via JNI (Vosk/JNA) e rompe la release.
    sed -i -E 's/^( *)signingConfig = signingConfigs\.getByName\("debug"\)/\1signingConfig = signingConfigs.getByName("debug")\n\1isMinifyEnabled = false\n\1isShrinkResources = false/' "$G"
    grep -q 'isMinifyEnabled = false' "$G" || { echo "minify non disattivato"; cat "$G"; exit 1; }
    # Vosk: riconoscimento offline della frase "Ciao Dom".
    cat >> "$G" <<'GRADLE'

dependencies {
    implementation("com.alphacephei:vosk-android:0.3.75@aar")
    implementation("net.java.dev.jna:jna:5.18.1@aar")
}
GRADLE
  fi
done

flutter pub get
