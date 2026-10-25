package de.jasonstream.exoplayer

import android.os.Handler
import android.os.Looper
import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.mserref.NtStatus
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2Dialect
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.mssmb2.SMBApiException
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import com.hierynomus.smbj.share.File
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedOutputStream
import java.io.FileInputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.EnumSet
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Netzlaufwerk (SMB 2/3, Bibliothek smbj, Apache-2.0) – Kanal
 * „de.jasonstream/smb“. SMB1 wird bewusst nicht unterstützt (smbj kann es
 * nicht; Server, die nur SMB1 sprechen, liefern den Code „smb1“).
 *
 * - test/free: Verbindung prüfen, freier/gesamter Platz der Freigabe
 * - open/write/close/size/delete/list/mkdirs: Downloads direkt aufs NAS
 * - upload: lokale Datei (fertige Aufnahme) aufs NAS kopieren
 * - serve: Datei über einen lokalen HTTP-Proxy (127.0.0.1, Zufallstoken,
 *   Range) für mpv/ExoPlayer bereitstellen
 *
 * Fehler gehen als PlatformException mit Code aus [SmbLogic.classify] an Dart;
 * Passwörter erscheinen nie in Fehlertexten.
 */
class SmbBridge(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "de.jasonstream/smb")
    private val io = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())
    private val config: SmbConfig = SmbConfig.builder()
        .withDialects(SMB2Dialect.SMB_3_1_1, SMB2Dialect.SMB_3_0_2, SMB2Dialect.SMB_3_0,
            SMB2Dialect.SMB_2_1, SMB2Dialect.SMB_2_0_2)
        .withTimeout(20, TimeUnit.SECONDS)
        .withSoTimeout(30, TimeUnit.SECONDS)
        .withEncryptData(false)
        .build()
    private val client = SMBClient(config)

    private class Conn(val connection: Connection, val session: Session, val share: DiskShare)
    private val conns = ConcurrentHashMap<String, Conn>()

    private class Handle(val target: SmbTarget, val file: File, var offset: Long)
    private val handles = ConcurrentHashMap<Int, Handle>()
    private val nextHandle = AtomicInteger(1)

    private var proxy: SmbProxy? = null

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        io.execute {
            for (h in handles.values) runCatching { h.file.close() }
            handles.clear()
            for (c in conns.values) runCatching { c.connection.close() }
            conns.clear()
            runCatching { client.close() }
        }
        proxy?.stop()
        proxy = null
        io.shutdown()
    }

    @Synchronized
    private fun share(t: SmbTarget, fresh: Boolean = false): DiskShare {
        val old = conns[t.key]
        if (!fresh && old != null && old.connection.isConnected && old.share.isConnected) return old.share
        old?.let { runCatching { it.connection.close() } }
        conns.remove(t.key)
        val conn = client.connect(t.host, t.port)
        try {
            val auth = if (t.user.isEmpty()) AuthenticationContext.guest()
            else AuthenticationContext(t.user, t.password.toCharArray(), t.domain.ifEmpty { null })
            val session = conn.authenticate(auth)
            val s = session.connectShare(t.share) as? DiskShare
                ?: throw IllegalStateException("not a disk share")
            conns[t.key] = Conn(conn, session, s)
            return s
        } catch (e: Exception) {
            runCatching { conn.close() }
            throw e
        }
    }

    /** Einmal mit frischer Verbindung wiederholen (NAS im Ruhezustand, WLAN-Wechsel). */
    private fun <T> withShare(t: SmbTarget, f: (DiskShare) -> T): T = try {
        f(share(t))
    } catch (e: SMBApiException) {
        throw e
    } catch (e: Exception) {
        f(share(t, fresh = true))
    }

    private fun mkdirs(s: DiskShare, dir: String) {
        if (dir.isEmpty()) return
        var cur = ""
        for (p in dir.split('\\')) {
            cur = if (cur.isEmpty()) p else "$cur\\$p"
            if (!s.folderExists(cur)) s.mkdir(cur)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        io.execute {
            try {
                val r = handle(call.method, args)
                main.post { result.success(r) }
            } catch (e: NotImplementedError) {
                main.post { result.notImplemented() }
            } catch (e: Throwable) {
                val status = (e as? SMBApiException)?.status?.name
                    ?: ((e.cause as? SMBApiException)?.status?.name)
                val code = SmbLogic.classify(e.javaClass.name, e.message ?: e.cause?.message, status)
                main.post { result.error(code, status ?: e.javaClass.simpleName, null) }
            }
        }
    }

    private fun target(args: Map<*, *>?): SmbTarget =
        SmbTarget.from(args?.get("cfg") as? Map<*, *>) ?: throw IllegalArgumentException("config")

    private fun rel(args: Map<*, *>?): String = (args?.get("rel") as? String).orEmpty()

    private fun handle(method: String, args: Map<*, *>?): Any? = when (method) {
        "test" -> {
            val t = target(args)
            withShare(t, { s ->
                // Basisordner anlegen bzw. prüfen; Platz abfragen.
                mkdirs(s, t.base)
                val info = runCatching { s.shareInformation }.getOrNull()
                mapOf(
                    "free" to (info?.callerFreeSpace ?: -1L),
                    "total" to (info?.totalSpace ?: -1L),
                    "dialect" to (conns[t.key]?.connection?.connectionContext?.negotiatedProtocol?.dialect?.name ?: ""),
                )
            })
        }
        "free" -> {
            val t = target(args)
            withShare(t, { s -> runCatching { s.shareInformation.callerFreeSpace }.getOrDefault(-1L) })
        }
        "size" -> {
            val t = target(args)
            val p = t.path(rel(args))
            withShare(t, { s ->
                if (!s.fileExists(p)) -1L
                else s.getFileInformation(p).standardInformation.endOfFile
            })
        }
        "open" -> {
            val t = target(args)
            val p = t.path(rel(args))
            val append = args?.get("append") == true
            withShare(t, { s ->
                mkdirs(s, SmbLogic.parent(p))
                val f = s.openFile(
                    p,
                    EnumSet.of(AccessMask.GENERIC_WRITE, AccessMask.GENERIC_READ),
                    EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),
                    SMB2ShareAccess.ALL,
                    if (append) SMB2CreateDisposition.FILE_OPEN_IF else SMB2CreateDisposition.FILE_OVERWRITE_IF,
                    null,
                )
                val off = if (append) f.fileInformation.standardInformation.endOfFile else 0L
                val id = nextHandle.getAndIncrement()
                handles[id] = Handle(t, f, off)
                id
            })
        }
        "write" -> {
            val id = (args?.get("handle") as Number).toInt()
            val bytes = args["bytes"] as ByteArray
            val h = handles[id] ?: throw IllegalStateException("handle")
            h.file.write(bytes, h.offset)
            h.offset += bytes.size
            null
        }
        "close" -> {
            val id = (args?.get("handle") as Number).toInt()
            handles.remove(id)?.let { runCatching { it.file.flush() }; it.file.close() }
            null
        }
        "delete" -> {
            val t = target(args)
            val p = t.path(rel(args))
            withShare(t, { s ->
                if (s.fileExists(p)) {
                    s.rm(p)
                    true
                } else false
            })
        }
        "list" -> {
            val t = target(args)
            val dir = t.path(rel(args))
            withShare(t, { s ->
                if (!s.folderExists(dir)) emptyList<Map<String, Any>>()
                else s.list(dir).filter {
                    val n = it.fileName
                    n != "." && n != ".." && !n.startsWith(".") &&
                        (it.fileAttributes and FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value) == 0L
                }.map {
                    mapOf(
                        "name" to it.fileName,
                        "size" to it.endOfFile,
                        "modified" to it.lastWriteTime.toEpochMillis(),
                    )
                }
            })
        }
        "upload" -> {
            val t = target(args)
            val local = java.io.File(args?.get("local") as String)
            val p = t.path(rel(args))
            withShare(t, { s ->
                mkdirs(s, SmbLogic.parent(p))
                val f = s.openFile(p, EnumSet.of(AccessMask.GENERIC_WRITE), null, SMB2ShareAccess.ALL,
                    SMB2CreateDisposition.FILE_OVERWRITE_IF, null)
                f.use { file ->
                    FileInputStream(local).use { input ->
                        val buf = ByteArray(1 shl 20)
                        var off = 0L
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            file.write(buf, off, 0, n)
                            off += n
                        }
                    }
                }
                // Vollständig? (Größe vergleichen, erst dann löscht Dart lokal.)
                val remote = s.getFileInformation(p).standardInformation.endOfFile
                if (remote != local.length()) throw java.io.IOException("size mismatch")
                remote
            })
        }
        "serve" -> {
            val t = target(args)
            val p = t.path(rel(args))
            val px = proxy ?: SmbProxy { tt, path, start, len, out -> stream(tt, path, start, len, out) }
                .also { it.start(); proxy = it }
            val size = withShare(t, { s -> s.getFileInformation(p).standardInformation.endOfFile })
            px.publish(t, p, size)
        }
        else -> throw NotImplementedError()
    }

    private fun stream(t: SmbTarget, path: String, start: Long, len: Long, out: java.io.OutputStream) {
        withShare(t, { s ->
            s.openFile(path, EnumSet.of(AccessMask.GENERIC_READ), null, SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OPEN, null).use { f ->
                val buf = ByteArray(256 * 1024)
                var pos = start
                var left = len
                while (left > 0) {
                    val n = f.read(buf, pos, 0, minOf(buf.size.toLong(), left).toInt())
                    if (n <= 0) break
                    out.write(buf, 0, n)
                    pos += n
                    left -= n
                }
                out.flush()
            }
        })
    }

    @Suppress("unused")
    private fun isAuth(e: SMBApiException) = e.status == NtStatus.STATUS_LOGON_FAILURE
}

/**
 * Lokaler HTTP-Server nur auf 127.0.0.1 (Zufallstoken je Datei), damit
 * mpv und ExoPlayer NAS-Dateien mit Spulen (Range) abspielen können.
 */
class SmbProxy(private val read: (SmbTarget, String, Long, Long, java.io.OutputStream) -> Unit) {
    private class Entry(val target: SmbTarget, val path: String, val size: Long)
    private val entries = ConcurrentHashMap<String, Entry>()
    private var server: ServerSocket? = null
    private val pool = Executors.newCachedThreadPool()
    private val rnd = SecureRandom()

    fun start() {
        val s = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
        server = s
        pool.execute {
            while (!s.isClosed) {
                val c = runCatching { s.accept() }.getOrNull() ?: break
                pool.execute { serve(c) }
            }
        }
    }

    fun stop() {
        runCatching { server?.close() }
        pool.shutdownNow()
    }

    fun publish(t: SmbTarget, path: String, size: Long): String {
        val token = ByteArray(16).also { rnd.nextBytes(it) }.joinToString("") { "%02x".format(it) }
        entries[token] = Entry(t, path, size)
        val name = path.substringAfterLast('\\')
        return "http://127.0.0.1:${server!!.localPort}/$token/${java.net.URLEncoder.encode(name, "UTF-8")}"
    }

    private fun serve(c: Socket) {
        c.use { sock ->
            sock.soTimeout = 30000
            val input = sock.getInputStream().bufferedReader(Charsets.ISO_8859_1)
            val first = input.readLine() ?: return
            val parts = first.split(' ')
            if (parts.size < 2) return
            val method = parts[0]
            val token = parts[1].trimStart('/').substringBefore('/')
            var range: String? = null
            while (true) {
                val l = input.readLine() ?: break
                if (l.isEmpty()) break
                if (l.lowercase().startsWith("range:")) range = l.substringAfter(':').trim()
            }
            val out = BufferedOutputStream(sock.getOutputStream(), 64 * 1024)
            val e = entries[token]
            if (e == null || (method != "GET" && method != "HEAD")) {
                out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                out.flush()
                return
            }
            val r = SmbLogic.range(range, e.size)
            val start = r?.first ?: 0L
            val end = r?.second ?: (e.size - 1)
            val len = if (e.size == 0L) 0L else end - start + 1
            val head = StringBuilder()
            head.append(if (r != null) "HTTP/1.1 206 Partial Content\r\n" else "HTTP/1.1 200 OK\r\n")
            head.append("Content-Type: ${SmbLogic.mime(e.path)}\r\n")
            head.append("Accept-Ranges: bytes\r\n")
            head.append("Content-Length: $len\r\n")
            if (r != null) head.append("Content-Range: bytes $start-$end/${e.size}\r\n")
            head.append("Connection: close\r\n\r\n")
            out.write(head.toString().toByteArray())
            if (method == "GET" && len > 0) {
                runCatching { read(e.target, e.path, start, len, out) }
            }
            runCatching { out.flush() }
        }
    }
}
