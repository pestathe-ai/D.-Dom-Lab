package dev.domlab.dom_lab

import android.content.Context
import android.util.Log
import org.vosk.LibVosk
import org.vosk.LogLevel
import org.vosk.Model
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream

/**
 * Il modello vocale italiano di Vosk (circa 50 MB): serve per "Ciao Dom" e
 * come riconoscitore di riserva, tutto offline. Si scarica una volta.
 */
object VoskModel {
    private const val TAG = "DomVosk"
    const val URL_IT = "https://alphacephei.com/vosk/models/vosk-model-small-it-0.22.zip"
    const val DIR = "vosk-model-small-it-0.22"

    /** missing, downloading N, loading, ready, error ... */
    @Volatile
    var status: String = "missing"
        private set

    @Volatile
    var model: Model? = null
        private set

    private val lock = Any()

    /** Parole che il modello conosce (se il file c'è). */
    @Volatile
    var words: Set<String>? = null
        private set

    fun dir(c: Context) = File(c.filesDir, DIR)

    fun downloaded(c: Context) = File(dir(c), "am/final.mdl").exists() || File(dir(c), "conf/model.conf").exists()

    fun refreshStatus(c: Context): String {
        if (model != null) status = "ready"
        else if (!status.startsWith("downloading") && status != "loading" && !status.startsWith("error")) {
            status = if (downloaded(c)) "downloaded" else "missing"
        }
        return status
    }

    /** Scarica (se serve) e carica il modello. Bloccante: chiamare da un thread. */
    fun ensure(c: Context): Model {
        synchronized(lock) {
            model?.let { return it }
            try {
                if (!downloaded(c)) download(c)
                status = "loading"
                LibVosk.setLogLevel(LogLevel.WARNINGS)
                val m = Model(dir(c).absolutePath)
                words = readWords(c)
                model = m
                status = "ready"
                return m
            } catch (e: Exception) {
                Log.e(TAG, "modello", e)
                status = "error ${e.message ?: e.javaClass.simpleName}"
                throw e
            }
        }
    }

    /** Avvia download e caricamento in background. */
    fun prepareAsync(c: Context) {
        if (model != null || status.startsWith("downloading") || status == "loading") return
        val app = c.applicationContext
        Thread {
            try {
                ensure(app)
            } catch (_: Exception) {
            }
        }.start()
    }

    private fun readWords(c: Context): Set<String>? {
        val f = listOf("graph/words.txt", "words.txt").map { File(dir(c), it) }.firstOrNull { it.exists() } ?: return null
        return try {
            f.readLines().mapNotNull { it.substringBefore(' ').trim().takeIf { w -> w.isNotEmpty() } }.toHashSet()
        } catch (_: Exception) {
            null
        }
    }

    private fun download(c: Context) {
        status = "downloading 0"
        val tmp = File(c.cacheDir, "vosk-it.zip")
        var url = URL_IT
        var conn: HttpURLConnection
        var hops = 0
        while (true) {
            conn = URL(url).openConnection() as HttpURLConnection
            conn.instanceFollowRedirects = true
            conn.connectTimeout = 20000
            conn.readTimeout = 30000
            val code = conn.responseCode
            if (code in 300..399 && hops < 5) {
                url = conn.getHeaderField("Location") ?: break
                conn.disconnect()
                hops++
                continue
            }
            if (code != 200) throw IllegalStateException("download HTTP $code")
            break
        }
        val total = conn.contentLengthLong.coerceAtLeast(1)
        conn.inputStream.use { input ->
            FileOutputStream(tmp).use { out ->
                val buf = ByteArray(64 * 1024)
                var done = 0L
                while (true) {
                    val r = input.read(buf)
                    if (r < 0) break
                    out.write(buf, 0, r)
                    done += r
                    status = "downloading ${(done * 100 / total).coerceAtMost(100)}"
                }
            }
        }
        conn.disconnect()
        val dest = c.filesDir
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
        if (!downloaded(c)) throw IllegalStateException("modello vocale incompleto")
    }

    // ---------- Frase di attivazione ----------

    /** Varianti di "Dom" che il riconoscitore potrebbe sentire. */
    private val DOM_VARIANTS = listOf("dom", "don", "domo", "dome", "doma", "dong", "tom", "ton", "dum", "domm", "dov", "do")

    /** Grammatica: solo "ciao" + varianti di Dom; tutto il resto è [unk]. */
    fun wakeGrammar(): String {
        val known = words
        val variants = if (known == null) DOM_VARIANTS else DOM_VARIANTS.filter { it in known }.ifEmpty { DOM_VARIANTS }
        val phrases = variants.map { "\"ciao $it\"" } + listOf("\"ciao\"", "\"[unk]\"")
        return phrases.joinToString(", ", "[", "]")
    }

    /** Vero se il testo riconosciuto è "Ciao Dom" (o quasi). */
    fun isWakePhrase(text: String): Boolean {
        val t = text.lowercase().trim()
        return Regex("\\bciao\\s+(" + DOM_VARIANTS.joinToString("|") + ")\\b").containsMatchIn(t)
    }
}
