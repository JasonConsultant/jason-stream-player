package de.jasonstream.core.ui

/**
 * Farbwelt von Jason Stream Player (Port von lib/core/theme.dart, ohne
 * Compose-Abhängigkeit): tiefes Tinten-Blau, Akzent nach Einstellung
 * „set_accent“, Rot für „Live“, Türkis für „Catch-up“. Werte als ARGB-Int
 * (Compose: `Color(AppPalette.bg)`).
 */
object AppPalette {
    const val bg = 0xFF090B10.toInt()
    const val surface = 0xFF11141B.toInt()
    const val surface2 = 0xFF181C25.toInt()
    const val surface3 = 0xFF222733.toInt()
    const val line = 0xFF2A303D.toInt()
    const val text = 0xFFF2F4F8.toInt()
    const val textDim = 0xFF9AA3B5.toInt()
    const val textFaint = 0xFF636C7E.toInt()
    const val live = 0xFFFF4D5E.toInt()
    const val catchup = 0xFF2CC9A6.toInt()
    const val gold = 0xFFFFC857.toInt()
    /** Schrift auf Akzentfarbe (onPrimary). */
    const val onAccent = 0xFF1A0B04.toInt()

    const val DEFAULT_ACCENT = "orange"

    /** Vorgaben – Kontrast ≥ 4,5:1 auf bg/surface3 (WCAG AA). */
    val accentPresets: Map<String, Int> = linkedMapOf(
        "orange" to 0xFFFF7A45.toInt(),
        "blau" to 0xFF5AA2FF.toInt(),
        "gruen" to 0xFF3DD68C.toInt(),
        "lila" to 0xFFB48CFF.toInt(),
        "rot" to 0xFFFF6470.toInt(),
        "tuerkis" to 0xFF22C7D6.toInt(),
    )

    /** Akzentfarbe zu einem Schlüssel (unbekannt → orange). */
    fun accent(key: String?): Int = accentPresets[key] ?: accentPresets.getValue(DEFAULT_ACCENT)

    /** accentSoft: Akzent mit Alpha 0x33. */
    fun accentSoft(key: String?): Int = (accent(key) and 0x00FFFFFF) or (0x33 shl 24)
}
