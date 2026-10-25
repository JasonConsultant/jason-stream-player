import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';

/// Darstellung eines Aktionsmenüs (Sender-Menü, Spurwahl, „⋮“-Menüs).
enum ActionSheetStyle {
  /// Fernseher: unverändert das bisherige Blatt (D-Pad-optimiert).
  tv,

  /// Handy (kürzere Seite < 600 dp): Material-3-Blatt mit Ziehgriff.
  sheet,

  /// Tablet: zentrierter Dialog.
  dialog,
}

ActionSheetStyle actionSheetStyleOf(BuildContext context) {
  var tv = false;
  try {
    tv = ProviderScope.containerOf(context, listen: false).read(isTvProvider);
  } catch (_) {
    // Ohne ProviderScope (einzelne Widget-Tests): wie Handy/Tablet.
  }
  if (tv) return ActionSheetStyle.tv;
  return MediaQuery.sizeOf(context).shortestSide >= 600
      ? ActionSheetStyle.dialog
      : ActionSheetStyle.sheet;
}

/// Aktionsmenü: Handy unten als Blatt mit Ziehgriff, Tablet als Dialog,
/// Fernseher wie bisher (Blatt mit genau den übergebenen Einstellungen).
///
/// [heightFactor]: Anteil der Bildschirmhöhe für hohe Inhalte (z. B. das
/// Sender-Menü mit Archiv); sonst passt sich die Höhe dem Inhalt an.
Future<T?> showActionSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = false,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  BoxConstraints? constraints,
  double? heightFactor,
}) {
  final style = actionSheetStyleOf(context);
  if (style == ActionSheetStyle.dialog) {
    final h = MediaQuery.sizeOf(context).height;
    final maxW = constraints?.maxWidth;
    return showDialog<T>(
      context: context,
      useRootNavigator: useRootNavigator,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: maxW == null || maxW.isInfinite ? 560 : maxW,
            maxHeight: h * 0.86,
          ),
          child: Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 8),
            child: heightFactor == null
                ? builder(ctx)
                : SizedBox(height: h * heightFactor, child: builder(ctx)),
          ),
        ),
      ),
    );
  }
  final phone = style == ActionSheetStyle.sheet;
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: useRootNavigator,
    isScrollControlled: isScrollControlled || heightFactor != null,
    useSafeArea: useSafeArea || (phone && heightFactor != null),
    showDragHandle: phone ? true : null,
    constraints: constraints,
    builder: heightFactor == null
        ? builder
        : (ctx) => FractionallySizedBox(
            heightFactor: heightFactor, child: builder(ctx)),
  );
}
