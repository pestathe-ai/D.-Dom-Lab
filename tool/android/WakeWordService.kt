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
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService

/** Impostazioni native condivise tra servizi e app. */
object Prefs {
    private fun sp(c: Context) = c.getSharedPreferences("dom_native", Context.MODE_PRIVATE)
    fun wake(c: Context) = sp(c).getBoolean("wake", false)
    fun setWake(c: Context, v: Boolean) = sp(c).edit().putBoolean("wake", v).apply()
    fun bubble(c: Context) = sp(c).getBoolean("bubble", true)
    fun setBubble(c: Context, v: Boolean) = sp(c).edit().putBoolean("bubble", v).apply()
}

/**
 * Servizio in primo piano col microfono.
 *  - Con "Ciao Dom" acceso ascolta in continuo solo quella frase (Vosk,
 *    offline) e sveglia l'assistente.
 *  - Mentre Dom lavora tiene il microfono disponibile anche quando è aperta
 *    un'altra app (Android lo concede solo ai servizi di questo tipo).
 */
class WakeWordService : Service(), RecognitionListener {

    companion object {
        private const val TAG = "DomWake"
        private const val CHANNEL = "dom_wake"
        private const val NOTIF_ID = 7

        @Volatile
        var instance: WakeWordService? = null
            private set

        /** off, session, loading, listening, paused, error ... */
        @Volatile
        var status: String = "off"

        /** Ultima frase sentita (per capire se "Ciao Dom" viene frainteso). */
        @Volatile
        var lastHeard: String = ""

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
    private var destroyed = false

    @Volatile
    private var preparing = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        try {
            startInForeground(if (Prefs.wake(this)) "In ascolto di \"Ciao Dom\"" else "Dom è al lavoro")
        } catch (e: Exception) {
            // Android non permette di usare il microfono da qui (es. avvio
            // in background): si riattiva aprendo l'app.
            Log.e(TAG, "foreground", e)
            status = "error avvio in background non consentito"
            instance = null
            stopSelf()
            return
        }
        refresh()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        destroyed = true
        if (instance === this) instance = null
        stopMic()
        status = "off"
        super.onDestroy()
    }

    /** Applica l'impostazione "Ciao Dom" (accesa o spenta). */
    fun refresh() {
        if (Prefs.wake(this)) {
            paused = false
            if (speech == null && !preparing) {
                preparing = true
                status = "loading"
                Thread {
                    try {
                        VoskModel.ensure(this)
                        main.post { startMic() }
                    } catch (e: Exception) {
                        status = "error ${e.message}"
                        updateNotification("Errore: ${e.message}")
                    } finally {
                        preparing = false
                    }
                }.start()
            }
        } else {
            main.post { stopMic() }
            status = "session"
            updateNotification("Dom è al lavoro")
        }
    }

    private fun startInForeground(text: String) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Microfono di Dom", NotificationManager.IMPORTANCE_LOW))
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

    private fun startMic() {
        if (destroyed || paused || speech != null || !Prefs.wake(this)) return
        val m = VoskModel.model ?: return
        try {
            val rec = Recognizer(m, 16000.0f, VoskModel.wakeGrammar())
            speech = SpeechService(rec, 16000.0f).also { it.startListening(this) }
            status = "listening"
            updateNotification("In ascolto di \"Ciao Dom\"")
        } catch (e: Exception) {
            Log.e(TAG, "microfono", e)
            status = "error microfono occupato"
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
            status = if (Prefs.wake(this)) "paused" else "session"
        }
    }

    fun resume() {
        main.post {
            paused = false
            startMic()
        }
    }

    private fun check(json: String?, final: Boolean) {
        if (json == null || paused) return
        val text = try {
            val o = JSONObject(json)
            o.optString("text", o.optString("partial", ""))
        } catch (_: Exception) {
            ""
        }
        if (final && text.isNotBlank() && text != "[unk]") lastHeard = text
        if (VoskModel.isWakePhrase(text)) {
            Log.i(TAG, "attivazione: $text")
            lastHeard = text
            pause()
            main.post { wake() }
        }
    }

    private fun wake() {
        // App già viva: le passa il comando senza cambiare schermata.
        if (MainActivity.deliverWake("voice")) return
        val intent = Intent(this, MainActivity::class.java).putExtra("wake", "voice")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        val a11y = DomA11yService.instance
        if (a11y != null && a11y.launch(intent)) return
        try {
            startActivity(intent)
        } catch (_: Exception) {
            resume()
        }
    }

    override fun onPartialResult(hypothesis: String?) = check(hypothesis, false)
    override fun onResult(hypothesis: String?) = check(hypothesis, true)
    override fun onFinalResult(hypothesis: String?) = check(hypothesis, true)
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
