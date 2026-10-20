package de.jasonstream.player

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodChannel
import java.io.FileOutputStream
import java.io.OutputStream

/**
 * Aufnahme-Speicherort außerhalb des App-Ordners (USB-Stick, SD-Karte,
 * Netzlaufwerk) über das Storage Access Framework: Der Nutzer wählt einen
 * Ordner (Dokumentbaum), die App bekommt dauerhaften Lese-/Schreibzugriff.
 *
 * Netzlaufwerke (SMB/NAS) funktionieren nur, wenn eine Anbieter-App einen
 * Dokumentbaum dafür bereitstellt (z. B. CX File Explorer, Solid Explorer,
 * auf Android TV die eingebauten SMB-Anbieter mancher Hersteller).
 */
object RecStorage {
    const val PICK_TREE_REQUEST = 4720
    const val MIME = "video/mp2t"

    private var pending: MethodChannel.Result? = null

    fun pickTree(activity: Activity, result: MethodChannel.Result) {
        pending?.success(null)
        pending = result
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
                    .addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                    ),
                PICK_TREE_REQUEST
            )
        } catch (e: Exception) {
            pending = null
            result.error("nopicker", "Kein Ordnerauswahl-Dialog verfügbar", null)
        }
    }

    /** Von MainActivity.onActivityResult aufgerufen. true = war unser Request. */
    fun onActivityResult(ctx: Context, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_TREE_REQUEST) return false
        val result = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null); return true
        }
        try {
            // Alte Freigaben loslassen (Android begrenzt die Anzahl).
            for (p in ctx.contentResolver.persistedUriPermissions) {
                if (p.uri != uri) try {
                    ctx.contentResolver.releasePersistableUriPermission(
                        p.uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (_: Exception) {}
            }
            ctx.contentResolver.takePersistableUriPermission(
                uri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
            result.success(mapOf("uri" to uri.toString(), "name" to treeName(ctx, uri)))
        } catch (e: Exception) {
            result.error("perm", e.javaClass.simpleName, null)
        }
        return true
    }

    fun hasPermission(ctx: Context, tree: String): Boolean =
        ctx.contentResolver.persistedUriPermissions.any {
            it.uri.toString() == tree && it.isReadPermission && it.isWritePermission
        }

    /** Anzeigename des Ordners (letzter Pfadteil, z. B. "Aufnahmen" oder Laufwerk). */
    fun treeName(ctx: Context, tree: Uri): String {
        val doc = DocumentsContract.buildDocumentUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree)
        )
        try {
            ctx.contentResolver.query(
                doc, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null
            )?.use { c -> if (c.moveToFirst()) c.getString(0)?.let { if (it.isNotBlank()) return it } }
        } catch (_: Exception) {}
        val id = DocumentsContract.getTreeDocumentId(tree)
        // "primary:Movies/Rec" → "Rec"; "1234-ABCD:" → "1234-ABCD"
        val path = id.substringAfter(':', id)
        return path.trimEnd('/').substringAfterLast('/').ifBlank { id.substringBefore(':') }
    }

    /** Freier Platz in Bytes, -1 wenn nicht ermittelbar. */
    fun freeSpace(ctx: Context, tree: Uri): Long {
        return try {
            val doc = DocumentsContract.buildDocumentUriUsingTree(
                tree, DocumentsContract.getTreeDocumentId(tree)
            )
            ctx.contentResolver.openFileDescriptor(doc, "r")?.use { pfd ->
                val st = android.system.Os.fstatvfs(pfd.fileDescriptor)
                st.f_bavail * st.f_bsize
            } ?: -1L
        } catch (_: Exception) {
            -1L
        }
    }

    fun info(ctx: Context, tree: String): Map<String, Any?> {
        val uri = Uri.parse(tree)
        val ok = hasPermission(ctx, tree)
        return mapOf(
            "name" to (if (ok) try { treeName(ctx, uri) } catch (_: Exception) { "" } else ""),
            "free" to (if (ok) freeSpace(ctx, uri) else -1L),
            "granted" to ok,
        )
    }

    fun listRecordings(ctx: Context, tree: Uri): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree)
        )
        val cols = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
        )
        ctx.contentResolver.query(children, cols, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(1) ?: continue
                val mime = c.getString(4) ?: ""
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) continue
                if (!name.endsWith(".ts") && !name.endsWith(".mkv")) continue
                val docUri = DocumentsContract.buildDocumentUriUsingTree(tree, c.getString(0))
                out.add(
                    mapOf(
                        "name" to name,
                        "size" to c.getLong(2),
                        "lastModified" to c.getLong(3),
                        "documentUri" to docUri.toString(),
                    )
                )
            }
        }
        out.sortByDescending { it["lastModified"] as Long }
        return out
    }

    fun deleteRecording(ctx: Context, documentUri: Uri): Boolean =
        try { DocumentsContract.deleteDocument(ctx.contentResolver, documentUri) } catch (_: Exception) { false }

    /** Neue Datei im Baum anlegen; liefert deren Dokument-URI. */
    fun createDocument(ctx: Context, tree: Uri, displayName: String): Uri {
        val parent = DocumentsContract.buildDocumentUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree)
        )
        return DocumentsContract.createDocument(ctx.contentResolver, parent, MIME, displayName)
            ?: throw IllegalStateException("createDocument failed")
    }

    /**
     * Ausgabestrom für die Aufnahme (anhängend). Über einen
     * ParcelFileDescriptor, damit der Aufnahme-Thread wie in eine normale
     * Datei schreiben kann.
     */
    fun openOutput(ctx: Context, tree: Uri, displayName: String): Pair<Uri, OutputStream> {
        val doc = createDocument(ctx, tree, displayName)
        // "wa" (anhängen) unterstützen nicht alle Anbieter → dann "w".
        val pfd: ParcelFileDescriptor =
            (try { ctx.contentResolver.openFileDescriptor(doc, "wa") } catch (_: Exception) { null })
                ?: ctx.contentResolver.openFileDescriptor(doc, "w")
                ?: throw IllegalStateException("openFileDescriptor failed")
        val stream = object : FileOutputStream(pfd.fileDescriptor) {
            override fun close() {
                try { super.close() } finally { pfd.close() }
            }
        }
        return doc to stream
    }
}
