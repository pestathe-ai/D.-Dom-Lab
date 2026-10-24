package dev.domlab.dom_lab

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import org.json.JSONObject
import org.vosk.LibVosk
import org.vosk.LogLevel
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream

/** Impostazioni native condivise tra servizi e app. */
object Prefs {
    private fun sp(c: Context) = c.getSharedPreferences("dom_native", Context.MODE_PRIVATE)
    fun wake(c: Context) = sp(c).getBoolean("wake", false)
    fun setWake(c: Context, v: Boolean) = sp(c).edit().putBoolean("wake", v).apply()
    fun bubble(c: Context) = sp(c).getBoolean("bubble", true)
    fun setBubble(c: Context, v: Boolean) = sp(c).edit().putBoolean("bubble", v).apply()
}

/**
 * Ascolta in continuo, sul telefono e senza internet, solo la frase
 * "Ciao Dom" (Vosk, modello italiano piccolo con grammatica ristretta).
 * Quando la sente, mette in pausa il microfono e sveglia l'assistente.
 */
class WakeWordService : Service(), RecognitionListener {

    companion object {
        private const val TAG = "DomWake"
        private const val CHANNEL = "dom_wake"
        private const val NOTIF_ID = 7
        const val MODEL_URL = "https://alphacephei.com/vosk/models/vosk-model-small-it-0.22.zip"
        const val MODEL_DIR = "vosk-model-small-it-0.22"

        @Volatile
        var instance: WakeWordService? = null
            private set

        /** Stato leggibile dall'app: off, downloading N%, loading, listening, paused, error. */
        @Volatile
        var status: String = "off"

        private var model: Model? = null

        fun modelDir(c: Context) = File(c.filesDir, MODEL_DIR)

        fun modelReady(c: Context) = File(modelDir(c), "am/final.mdl").exists() || File(modelDir(c), "conf/model.conf").exists()

        /** Parole che il riconoscitore può sentire: tutto il resto è [unk]. */
        private const val GRAMMAR = "[\"ciao dom\", \"ciao don\", \"ciao tom\", \"ciao domo\", \"ciao\", \"dom\", \"don\", \"[unk]\"]"

        /** Vero se il testo riconosciuto è la frase di attivazione. */
        fun isWakePhrase(text: String): Boolean =
            Regex("\\bciao\\s+(dom|don|tom|domo)\\b").containsMatchIn(text.lowercase())

        fun start(c: Context) {
            val i = Intent(c, WakeWordService::class.java)
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i) else c.startService(i)
        }

        fun stop(c: Context) {
            c.stopService(Intent(c, WakeWordService::class.java))
            status = "off"
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var speech: SpeechService? = null
    private var paused = false
    @Volatile
    private var preparing = false
    private var destroyed = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        try {
            startInForeground("In ascolto di \"Ciao Dom\"")
        } catch (e: Exception) {
            // Android non permette di usare il microfono da qui (es. avvio
            // in background): si riattiva aprendo l'app.
            Log.e(TAG, "foreground", e)
            status = "error avvio"
            stopSelf()
            return
        }
        LibVosk.setLogLevel(LogLevel.WARNINGS)
        refresh()
    }

    /**
     * Senza "Ciao Dom" attivo il servizio resta acceso solo mentre Dom lavora
     * (serve ad Android per lasciare il microfono all'assistente anche
     * quando è aperta un'altra app).
     */
    fun refresh() {
        if (Prefs.wake(this)) {
            paused = false
            if (speech == null && !preparing) {
                preparing = true
                Thread {
                    prepareAndListen()
                    preparing = false
                }.start()
            }
        } else {
            main.post { stopMic() }
            status = "session"
            updateNotification("Dom è al lavoro")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        destroyed = true
        instance = null
        stopMic()
        status = "off"
        super.onDestroy()
    }

    private fun startInForeground(text: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Ascolto \"Ciao Dom\"", NotificationManager.IMPORTANCE_LOW))
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).putExtra("wake", "notification"),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val n: Notification = (if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this))
            .setContentTitle("D. Dom Lab")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 30) {
            startForeground(NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIF_ID, n)
        }
    }

    private fun updateNotification(text: String) {
        try {
            startInForeground(text)
        } catch (_: Exception) {
        }
    }

    private fun prepareAndListen() {
        try {
            if (!modelReady(this)) {
                status = "downloading 0"
                downloadModel()
            }
            if (destroyed) return
            status = "loading"
            if (model == null) model = Model(modelDir(this).absolutePath)
            main.post { startMic() }
        } catch (e: Exception) {
            Log.e(TAG, "preparazione", e)
            status = "error ${e.message}"
            updateNotification("Errore: ${e.message}")
        }
    }

    /** Scarica e scompatta il modello italiano (circa 50 MB, una volta sola). */
    private fun downloadModel() {
        val tmp = File(cacheDir, "vosk-it.zip")
        var conn = URL(MODEL_URL).openConnection() as HttpURLConnection
        conn.instanceFollowRedirects = true
        conn.connectTimeout = 20000
        conn.readTimeout = 30000
        if (conn.responseCode in 300..399) {
            val loc = conn.getHeaderField("Location")
            conn.disconnect()
            conn = URL(loc).openConnection() as HttpURLConnection
        }
        val total = conn.contentLengthLong.coerceAtLeast(1)
        conn.inputStream.use { input ->
            FileOutputStream(tmp).use { out ->
                val buf = ByteArray(64 * 1024)
                var done = 0L
                var lastPct = -1
                while (true) {
                    if (destroyed) return
                    val r = input.read(buf)
                    if (r < 0) break
                    out.write(buf, 0, r)
                    done += r
                    val pct = (done * 100 / total).toInt()
                    if (pct != lastPct) {
                        lastPct = pct
                        status = "downloading $pct"
                    }
                }
            }
        }
        conn.disconnect()
        val dest = filesDir
        ZipInputStream(tmp.inputStream().buffered()).use { zip ->
            while (true) {
                val e = zip.nextEntry ?: break
                val f = File(dest, e.name)
                if (!f.canonicalPath.startsWith(dest.canonicalPath)) continue
                if (e.isDirectory) {
                    f.mkdirs()
                } else {
                    f.parentFile?.mkdirs()
                    FileOutputStream(f).use { zip.copyTo(it) }
                }
            }
        }
        tmp.delete()
        if (!modelReady(this)) throw IllegalStateException("modello vocale incompleto")
    }

    private fun startMic() {
        if (destroyed || paused || speech != null) return
        val m = model ?: return
        try {
            val rec = Recognizer(m, 16000.0f, GRAMMAR)
            speech = SpeechService(rec, 16000.0f).also { it.startListening(this) }
            status = "listening"
            updateNotification("In ascolto di \"Ciao Dom\"")
        } catch (e: Exception) {
            Log.e(TAG, "microfono", e)
            status = "error ${e.message}"
            // Il microfono può essere occupato (chiamata, altra app): riprova.
            main.postDelayed({ startMic() }, 5000)
        }
    }

    private fun stopMic() {
        speech?.let {
            try {
                it.stop()
                it.shutdown()
            } catch (_: Exception) {
            }
        }
        speech = null
    }

    /** Libera il microfono mentre l'assistente ascolta il comando. */
    fun pause() {
        main.post {
            paused = true
            stopMic()
            status = "paused"
        }
    }

    fun resume() {
        main.post {
            paused = false
            startMic()
        }
    }

    private fun check(json: String?) {
        if (json == null || paused) return
        val text = try {
            val o = JSONObject(json)
            o.optString("text", o.optString("partial", ""))
        } catch (_: Exception) {
            ""
        }
        if (isWakePhrase(text)) {
            Log.i(TAG, "attivazione: $text")
            pause()
            main.post { wake() }
        }
    }

    private fun wake() {
        val a11y = DomA11yService.instance
        val intent = Intent(this, MainActivity::class.java).putExtra("wake", "voice")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        if (a11y != null && a11y.launch(intent)) return
        try {
            startActivity(intent)
        } catch (_: Exception) {
            resume()
        }
    }

    override fun onPartialResult(hypothesis: String?) = check(hypothesis)
    override fun onResult(hypothesis: String?) = check(hypothesis)
    override fun onFinalResult(hypothesis: String?) = check(hypothesis)
    override fun onError(exception: Exception?) {
        Log.e(TAG, "errore", exception)
        stopMic()
        main.postDelayed({ startMic() }, 3000)
    }

    override fun onTimeout() {
        stopMic()
        startMic()
    }
}
