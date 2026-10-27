import 'dart:io';

/// Nur private Netze: RFC 1918 (10/8, 172.16/12, 192.168/16), Link-Local
/// (169.254/16) und bei IPv6 Link-Local (fe80::/10) bzw. ULA (fc00::/7).
/// Öffentliche Adressen sind nie erlaubt – der Fernseher bietet den Dienst
/// nur im eigenen WLAN an (keine Port-Weiterleitung, kein UPnP).
bool isPrivateLan(InternetAddress a) {
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4 && b.length == 4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254);
  }
  if (a.type == InternetAddressType.IPv6 && b.length == 16) {
    // IPv4-gemappt (::ffff:a.b.c.d) → wie IPv4 prüfen.
    final mapped =
        b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
    if (mapped) {
      return isPrivateLan(InternetAddress.fromRawAddress(b.sublist(12)));
    }
    return (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || (b[0] & 0xfe) == 0xfc;
  }
  return false;
}

/// Darf ein Gegenüber mit Adresse [peer] verbinden? Privat immer; Loopback
/// nur, wenn der Server selbst auf Loopback lauscht (Tests).
bool isAllowedPeer(InternetAddress peer, {required bool loopbackServer}) =>
    isPrivateLan(peer) || (loopbackServer && peer.isLoopback);

/// Adresse, auf der der Fernseher lauscht: die erste private IPv4 (WLAN/LAN
/// vor Link-Local). `null` = kein privates Netz → Dienst startet nicht.
InternetAddress? pickPrivateLanAddress(List<InternetAddress> addresses) {
  final c = addresses
      .where((a) =>
          a.type == InternetAddressType.IPv4 && !a.isLoopback && isPrivateLan(a))
      .toList();
  int rank(InternetAddress a) {
    final b = a.rawAddress;
    if (b[0] == 192) return 0;
    if (b[0] == 10) return 1;
    if (b[0] == 172) return 2;
    return 3; // 169.254 Link-Local
  }

  if (c.isEmpty) return null;
  c.sort((a, b) => rank(a).compareTo(rank(b)));
  return c.first;
}

/// Private Adresse dieses Geräts (oder null).
Future<InternetAddress?> findPrivateLanAddress() async {
  try {
    final list = await NetworkInterface.list(
        type: InternetAddressType.IPv4, includeLoopback: false);
    return pickPrivateLanAddress([for (final i in list) ...i.addresses]);
  } catch (_) {
    return null;
  }
}
