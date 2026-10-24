package dev.domlab.dom_lab

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.AlarmClock
import android.provider.ContactsContract
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.telephony.SmsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.UUID

/**
 * Ponte tra Flutter e Android: voce (sintesi e riconoscimento), telefono
 * (contatti, chiamate, SMS, WhatsApp, mail, sveglie, app) e servizio di
 * accessibilità. Canale "domlab/native".
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private val ttsWaiting = HashMap<String, MethodChannel.Result>()
    private var recognizer: SpeechRecognizer? = null
    private var listenResult: MethodChannel.Result? = null
    private var pendingWake: String? = null
    private var permResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingWake = wakeExtra(intent)
        initTts()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "domlab/native")
        ch.setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: Exception) {
                result.error("native", e.message, null)
            }
        }
        channel = ch
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val w = wakeExtra(intent) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("wake", w) else pendingWake = w
    }

    private fun wakeExtra(i: Intent?): String? {
        if (i == null) return null
        if (i.action == Intent.ACTION_ASSIST || i.action == Intent.ACTION_VOICE_COMMAND) return "assist"
        return i.getStringExtra("wake")
    }

    override fun onDestroy() {
        recognizer?.destroy()
        recognizer = null
        tts?.shutdown()
        tts = null
        super.onDestroy()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        val a11y = DomA11yService.instance
        when (call.method) {
            // --- stato e impostazioni ---
            "takeWake" -> {
                result.success(pendingWake); pendingWake = null
            }
            "status" -> result.success(
                mapOf(
                    "a11y" to (a11y != null),
                    "mic" to has(Manifest.permission.RECORD_AUDIO),
                    "contacts" to has(Manifest.permission.READ_CONTACTS),
                    "phone" to has(Manifest.permission.CALL_PHONE),
                    "sms" to has(Manifest.permission.SEND_SMS),
                    "battery" to batteryFree(),
                    "wake" to Prefs.wake(this),
                    "wakeStatus" to WakeWordService.status,
                    "wakeModel" to WakeWordService.modelReady(this),
                    "bubble" to Prefs.bubble(this),
                    "package" to packageName,
                    "tts" to ttsReady,
                )
            )
            "openA11ySettings" -> {
                startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); result.success(true)
            }
            "openBatterySettings" -> {
                val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
                try {
                    startActivity(i)
                } catch (_: Exception) {
                    startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                }
                result.success(true)
            }
            "openAppSettings" -> {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))); result.success(true)
            }
            "openAssistantSettings" -> {
                result.success(openAssistantSettings())
            }
            "requestPermissions" -> {
                val wanted = mutableListOf(
                    Manifest.permission.RECORD_AUDIO,
                    Manifest.permission.READ_CONTACTS,
                    Manifest.permission.CALL_PHONE,
                    Manifest.permission.SEND_SMS,
                )
                if (Build.VERSION.SDK_INT >= 33) wanted.add(Manifest.permission.POST_NOTIFICATIONS)
                val missing = wanted.filter { !has(it) }
                if (missing.isEmpty()) {
                    result.success(true)
                } else {
                    permResult?.success(false)
                    permResult = result
                    requestPermissions(missing.toTypedArray(), 42)
                }
            }
            "setWake" -> {
                val on = call.argument<Boolean>("on") == true
                Prefs.setWake(this, on)
                if (on) {
                    val s = WakeWordService.instance
                    if (s != null) s.refresh() else WakeWordService.start(this)
                } else {
                    WakeWordService.stop(this)
                }
                result.success(true)
            }
            "setBubble" -> {
                val on = call.argument<Boolean>("on") == true
                Prefs.setBubble(this, on)
                if (on) a11y?.showBubble() else a11y?.hideBubble()
                result.success(true)
            }
            // Mentre Dom lavora: tiene il microfono disponibile anche con altre app aperte.
            "beginSession" -> {
                val s = WakeWordService.instance
                if (s != null) s.pause() else try {
                    WakeWordService.start(this)
                } catch (_: Exception) {
                }
                result.success(true)
            }
            "endSession" -> {
                val s = WakeWordService.instance
                if (Prefs.wake(this)) s?.resume() else if (s != null) WakeWordService.stop(this)
                result.success(true)
            }
            "bringToFront" -> {
                val i = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_NEW_TASK)
                if (a11y == null || !a11y.launch(i)) startActivity(i)
                result.success(true)
            }

            // --- voce ---
            "speak" -> speak(call.argument<String>("text") ?: "", result)
            "stopSpeaking" -> {
                tts?.stop(); ttsWaiting.values.forEach { it.success(true) }; ttsWaiting.clear(); result.success(true)
            }
            "listen" -> listen(call.argument<Int>("timeoutMs") ?: 8000, result)
            "stopListening" -> {
                recognizer?.cancel(); finishListen(null); result.success(true)
            }

            // --- schermo (servizio di accessibilità) ---
            "screen" -> result.success(a11y?.readScreen() ?: mapOf("package" to "", "nodes" to emptyList<Any>()))
            "tap" -> result.success(a11y?.tap(call.argument<Int>("id") ?: -1) ?: false)
            "type" -> result.success(a11y?.typeText(call.argument<Int>("id") ?: -1, call.argument<String>("text") ?: "") ?: false)
            "scroll" -> result.success(a11y?.scroll(call.argument<String>("direction") ?: "down") ?: false)
            "global" -> result.success(a11y?.global(call.argument<String>("action") ?: "") ?: false)

            // --- app e telefono ---
            "apps" -> result.success(apps())
            "openApp" -> {
                val pkg = call.argument<String>("package") ?: ""
                val i = packageManager.getLaunchIntentForPackage(pkg)
                result.success(i != null && launch(i))
            }
            "contacts" -> {
                val q = call.argument<String>("query") ?: ""
                Thread {
                    val out = try { findContacts(q) } catch (_: Exception) { emptyList() }
                    main.post { result.success(out) }
                }.start()
            }
            "call" -> {
                val n = call.argument<String>("number") ?: ""
                val ok = has(Manifest.permission.CALL_PHONE) &&
                    launch(Intent(Intent.ACTION_CALL, Uri.parse("tel:" + Uri.encode(n))))
                // Senza permesso apre almeno il tastierino col numero.
                if (!ok) launch(Intent(Intent.ACTION_DIAL, Uri.parse("tel:" + Uri.encode(n))))
                result.success(ok)
            }
            "sms" -> {
                val n = call.argument<String>("number") ?: ""
                val text = call.argument<String>("text") ?: ""
                result.success(sendSms(n, text))
            }
            "whatsapp" -> {
                val n = call.argument<String>("phone") ?: ""
                val text = call.argument<String>("text") ?: ""
                val uri = Uri.parse("https://api.whatsapp.com/send?phone=$n&text=" + Uri.encode(text))
                val i = Intent(Intent.ACTION_VIEW, uri)
                val pkg = listOf("com.whatsapp", "com.whatsapp.w4b").firstOrNull { installed(it) }
                if (pkg != null) i.setPackage(pkg)
                result.success(pkg != null && launch(i))
            }
            "email" -> {
                val to = call.argument<String>("to") ?: ""
                val i = Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:"))
                    .putExtra(Intent.EXTRA_EMAIL, arrayOf(to))
                    .putExtra(Intent.EXTRA_SUBJECT, call.argument<String>("subject") ?: "")
                    .putExtra(Intent.EXTRA_TEXT, call.argument<String>("body") ?: "")
                if (installed("com.google.android.gm")) i.setPackage("com.google.android.gm")
                result.success(launch(i))
            }
            "alarm" -> {
                val i = Intent(AlarmClock.ACTION_SET_ALARM)
                    .putExtra(AlarmClock.EXTRA_HOUR, call.argument<Int>("hour") ?: 7)
                    .putExtra(AlarmClock.EXTRA_MINUTES, call.argument<Int>("minute") ?: 0)
                    .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                val label = call.argument<String>("label") ?: ""
                if (label.isNotEmpty()) i.putExtra(AlarmClock.EXTRA_MESSAGE, label)
                result.success(launch(i))
            }
            "timer" -> {
                val i = Intent(AlarmClock.ACTION_SET_TIMER)
                    .putExtra(AlarmClock.EXTRA_LENGTH, call.argument<Int>("seconds") ?: 60)
                    .putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                val label = call.argument<String>("label") ?: ""
                if (label.isNotEmpty()) i.putExtra(AlarmClock.EXTRA_MESSAGE, label)
                result.success(launch(i))
            }
            "openUrl" -> result.success(launch(Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url") ?: ""))))
            "settings" -> result.success(openSettingsPanel(call.argument<String>("panel") ?: ""))
            else -> result.notImplemented()
        }
    }

    // ---------- Voce ----------

    private fun initTts() {
        tts = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                tts?.language = Locale.ITALIAN
                tts?.setSpeechRate(1.05f)
                ttsReady = true
            }
        }
        tts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) = doneSpeaking(utteranceId)
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) = doneSpeaking(utteranceId)
            override fun onError(utteranceId: String?, errorCode: Int) = doneSpeaking(utteranceId)
        })
    }

    private fun doneSpeaking(id: String?) {
        main.post {
            val r = ttsWaiting.remove(id ?: return@post) ?: return@post
            r.success(true)
        }
    }

    private fun speak(text: String, result: MethodChannel.Result) {
        val t = tts
        if (t == null || !ttsReady || text.isBlank()) {
            // Il motore può non essere pronto al primo avvio: riprova poco dopo.
            if (t != null && !ttsReady && text.isNotBlank()) {
                main.postDelayed({ if (ttsReady) speak(text, result) else result.success(false) }, 1200)
            } else {
                result.success(false)
            }
            return
        }
        val id = UUID.randomUUID().toString()
        ttsWaiting[id] = result
        val params = Bundle()
        params.putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, android.media.AudioManager.STREAM_MUSIC)
        if (t.speak(text, TextToSpeech.QUEUE_FLUSH, params, id) != TextToSpeech.SUCCESS) {
            ttsWaiting.remove(id)
            result.success(false)
        }
    }

    private fun listen(timeoutMs: Int, result: MethodChannel.Result) {
        if (!has(Manifest.permission.RECORD_AUDIO)) {
            result.error("mic", "Permesso microfono mancante", null); return
        }
        listenResult?.success(null)
        listenResult = result
        recognizer?.destroy()
        val r = if (Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(this) && preferOnDevice) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(this)
        } else {
            SpeechRecognizer.createSpeechRecognizer(this)
        }
        recognizer = r
        r.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
            override fun onError(error: Int) {
                // Il riconoscitore sul telefono non c'è o non ha l'italiano:
                // passa a quello standard e riprova una volta.
                if (preferOnDevice && (error == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED ||
                        error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE || error == SpeechRecognizer.ERROR_CLIENT ||
                        error == SpeechRecognizer.ERROR_SERVER)) {
                    preferOnDevice = false
                    val res = listenResult
                    listenResult = null
                    if (res != null) main.post { listen(timeoutMs, res) }
                    return
                }
                finishListen(null)
            }
            override fun onResults(results: Bundle?) {
                val list = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                finishListen(list?.firstOrNull())
            }
        })
        val i = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, "it-IT")
            .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            .putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1500L)
            .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 1200L)
        r.startListening(i)
        main.postDelayed({ if (listenResult === result) { r.cancel(); finishListen(null) } }, timeoutMs.toLong() + 15000)
    }

    private var preferOnDevice = false

    private fun finishListen(text: String?) {
        val r = listenResult ?: return
        listenResult = null
        main.post { r.success(text) }
    }

    // ---------- Telefono ----------

    private fun has(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    private fun installed(pkg: String) = try {
        packageManager.getPackageInfo(pkg, 0); true
    } catch (_: Exception) {
        false
    }

    private fun batteryFree(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun launch(i: Intent): Boolean {
        val a11y = DomA11yService.instance
        if (a11y != null && a11y.launch(Intent(i))) return true
        return try {
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (_: Exception) {
            false
        }
    }

    private fun apps(): List<Map<String, String>> {
        val i = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return packageManager.queryIntentActivities(i, 0)
            .map { mapOf("label" to it.loadLabel(packageManager).toString(), "package" to it.activityInfo.packageName) }
            .distinctBy { it["package"] }
    }

    @Suppress("UNCHECKED_CAST")
    private fun findContacts(query: String): List<Map<String, Any>> {
        if (!has(Manifest.permission.READ_CONTACTS) || query.isBlank()) return emptyList()
        val words = query.trim().split(Regex("\\s+")).filter { it.length > 1 }.take(3)
        val sel = words.joinToString(" OR ") { "${ContactsContract.Contacts.DISPLAY_NAME_PRIMARY} LIKE ?" }
        val args = words.map { "%$it%" }.toTypedArray()
        val byId = LinkedHashMap<Long, MutableMap<String, Any>>()
        contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            arrayOf(ContactsContract.Contacts._ID, ContactsContract.Contacts.DISPLAY_NAME_PRIMARY),
            sel, args, null
        )?.use { c ->
            while (c.moveToNext() && byId.size < 30) {
                byId[c.getLong(0)] = mutableMapOf("name" to (c.getString(1) ?: ""), "phones" to ArrayList<String>(), "emails" to ArrayList<String>())
            }
        }
        if (byId.isEmpty()) return emptyList()
        val ids = byId.keys.joinToString(",")
        contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Phone.CONTACT_ID, ContactsContract.CommonDataKinds.Phone.NUMBER),
            "${ContactsContract.CommonDataKinds.Phone.CONTACT_ID} IN ($ids)", null, null
        )?.use { c ->
            while (c.moveToNext()) {
                val v = c.getString(1)
                if (v != null) (byId[c.getLong(0)]?.get("phones") as? ArrayList<String>)?.add(v)
            }
        }
        contentResolver.query(
            ContactsContract.CommonDataKinds.Email.CONTENT_URI,
            arrayOf(ContactsContract.CommonDataKinds.Email.CONTACT_ID, ContactsContract.CommonDataKinds.Email.ADDRESS),
            "${ContactsContract.CommonDataKinds.Email.CONTACT_ID} IN ($ids)", null, null
        )?.use { c ->
            while (c.moveToNext()) {
                val v = c.getString(1)
                if (v != null) (byId[c.getLong(0)]?.get("emails") as? ArrayList<String>)?.add(v)
            }
        }
        return byId.values.toList()
    }

    private fun sendSms(number: String, text: String): Boolean {
        if (!has(Manifest.permission.SEND_SMS) || number.isBlank() || text.isBlank()) return false
        return try {
            val sms: SmsManager = if (Build.VERSION.SDK_INT >= 31) getSystemService(SmsManager::class.java) else @Suppress("DEPRECATION") SmsManager.getDefault()
            val parts = sms.divideMessage(text)
            sms.sendMultipartTextMessage(number, null, parts, null, null)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun openSettingsPanel(panel: String): Boolean {
        val action = when (panel.lowercase()) {
            "wifi" -> if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_WIFI else Settings.ACTION_WIFI_SETTINGS
            "internet", "dati" -> if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_INTERNET_CONNECTIVITY else Settings.ACTION_WIRELESS_SETTINGS
            "volume" -> if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_VOLUME else Settings.ACTION_SOUND_SETTINGS
            "nfc" -> if (Build.VERSION.SDK_INT >= 29) Settings.Panel.ACTION_NFC else Settings.ACTION_NFC_SETTINGS
            "bluetooth" -> Settings.ACTION_BLUETOOTH_SETTINGS
            "display", "luminosita" -> Settings.ACTION_DISPLAY_SETTINGS
            "battery", "batteria" -> Intent.ACTION_POWER_USAGE_SUMMARY
            "location", "posizione", "gps" -> Settings.ACTION_LOCATION_SOURCE_SETTINGS
            "airplane", "aereo" -> Settings.ACTION_AIRPLANE_MODE_SETTINGS
            else -> Settings.ACTION_SETTINGS
        }
        return launch(Intent(action))
    }

    /** Impostazioni per scegliere l'assistente predefinito (pressione lunga del tasto di accensione). */
    private fun openAssistantSettings(): Boolean {
        val tries = listOf(
            Intent(Settings.ACTION_VOICE_INPUT_SETTINGS),
            Intent("android.settings.MANAGE_DEFAULT_APPS_SETTINGS"),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (i in tries) {
            try {
                startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)); return true
            } catch (_: Exception) {
            }
        }
        return false
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 42) {
            permResult?.success(grantResults.all { it == PackageManager.PERMISSION_GRANTED })
            permResult = null
        }
    }
}
