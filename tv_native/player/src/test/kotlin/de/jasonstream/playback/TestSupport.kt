package de.jasonstream.playback

import de.jasonstream.core.model.Channel
import de.jasonstream.core.prefs.MemoryKeyValueStore
import de.jasonstream.core.security.SecretCipher
import de.jasonstream.core.storage.Storage

/** Klartext-„Verschlüsselung“ für Tests. */
object PlainCipher : SecretCipher {
    override fun encrypt(plain: String) = "p:$plain"
    override fun decrypt(cipher: String) = cipher.removePrefix("p:")
}

fun memStorage(initial: Map<String, Any> = emptyMap()): Storage = Storage.open(MemoryKeyValueStore(initial), PlainCipher)

fun ch(id: String, name: String = id, number: Int = 0, cat: String = "g", catchup: Int = 0, headers: Map<String, String>? = null) =
    Channel(id = id, name = name, categoryId = cat, streamUrl = "http://h/$id.ts", number = number, catchupDays = catchup, headers = headers)
