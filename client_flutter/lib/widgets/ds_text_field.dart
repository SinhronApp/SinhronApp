// Soft-fill text field. Matches design/app/entry.jsx DsTextField:
// - 50h container, 14r radius, 0 16px horizontal padding
// - Surface bg + hairline outline (or accent-soft glow when focused)
// - Optional uppercase label above (12/600 text-3, letter-spacing 0.6)
// - Optional prefix (text), suffix (widget) inside field
// - Mono variant for tokens/fingerprints uses GeistMono
//
// Note: §18.17 forbids Material defaults. We use CupertinoTextField (which
// internally wraps EditableText with iOS-native gesture handling — long-press
// → paste menu, double-tap → select word, etc.) and strip its visual chrome
// via `decoration: null` + `padding: EdgeInsets.zero`. Our outer container
// provides the bg + hairline border. Material's TextField is NOT used.
//
// Why not raw EditableText: per Flutter docs, EditableText is a low-level
// primitive with NO gesture handling — tap-to-focus, long-press-to-paste,
// selection toolbar are all in the wrapping widget (TextField/CupertinoTextField).
// We hit this 2026-05-23 on iPhone — user couldn't paste an identity hex
// because no context menu appeared. Switched to CupertinoTextField.

import 'package:flutter/cupertino.dart' show CupertinoTextField, CupertinoAdaptiveTextSelectionToolbar, CupertinoButton;
import 'package:flutter/services.dart';
// TextMagnifierConfiguration + SelectionChangedCause both live in widgets/.
import 'package:flutter/widgets.dart';

import '../app/theme/tokens.dart';
import '../l10n/l10n.dart';
import '../app/theme/palette.dart';

class DsTextField extends StatefulWidget {
  final String? label;
  final TextEditingController? controller;
  final String? hintText;
  final Widget? prefix;
  final Widget? suffix;
  final bool mono;
  final bool autofocus;
  final TextInputType keyboardType;
  final TextInputAction textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final bool obscureText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final FocusNode? focusNode;

  /// More than 1 → a taller field that wraps (recovery phrase entry).
  final int maxLines;

  /// For golden tests: force focused visual state without acquiring real focus.
  final bool? debugForceFocused;

  const DsTextField({
    super.key,
    this.label,
    this.controller,
    this.hintText,
    this.prefix,
    this.suffix,
    this.mono = false,
    this.autofocus = false,
    this.keyboardType = TextInputType.text,
    this.textInputAction = TextInputAction.done,
    this.inputFormatters,
    this.obscureText = false,
    this.onChanged,
    this.onSubmitted,
    this.enabled = true,
    this.focusNode,
    this.maxLines = 1,
    this.debugForceFocused,
  });

  @override
  State<DsTextField> createState() => _DsTextFieldState();
}

class _DsTextFieldState extends State<DsTextField> {
  late final TextEditingController _internalController;
  late final FocusNode _focusNode;
  bool _ownsController = false;
  bool _ownsFocusNode = false;

  @override
  void initState() {
    super.initState();
    _internalController = widget.controller ?? TextEditingController();
    _ownsController = widget.controller == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    if (_ownsFocusNode) _focusNode.dispose();
    if (_ownsController) _internalController.dispose();
    super.dispose();
  }

  void _onFocusChange() => setState(() {});

  bool get _isFocused => widget.debugForceFocused ?? _focusNode.hasFocus;

  @override
  Widget build(BuildContext context) {
    final tokens = DsTheme.of(context);

    final fontFamily = widget.mono ? DsType.familyMono : DsType.family;
    final fontSize = widget.mono ? 14.0 : 16.0;
    final textStyle = TextStyle(
      fontFamily: fontFamily,
      fontSize: fontSize,
      fontWeight: FontWeight.w500,
      letterSpacing: -0.1,
      height: widget.maxLines > 1 ? 1.35 : 1.0,
      color: tokens.text,
    );
    final hintStyle = textStyle.copyWith(color: tokens.text3);

    // The 24 words and pairing codes (audit storage-devices:18): the
    // keyboard must not learn, suggest or correct them.
    final secret = widget.keyboardType == TextInputType.visiblePassword;
    final field = CupertinoTextField(
      controller: _internalController,
      focusNode: _focusNode,
      style: textStyle,
      cursorColor: tokens.accent,
      // Disable the long-press magnifier loupe entirely — it was rendering
      // as a giant blank grey overlay because our 50px-tall container is
      // smaller than the loupe expects, and `RawMagnifier` defaulted to
      // unbounded size. We don't need the loupe for short hex inputs.
      magnifierConfiguration: TextMagnifierConfiguration.disabled,
      keyboardType: widget.keyboardType,
      autocorrect: !secret,
      enableSuggestions: !secret,
      enableIMEPersonalizedLearning: !secret,
      smartDashesType: secret ? SmartDashesType.disabled : null,
      smartQuotesType: secret ? SmartQuotesType.disabled : null,
      textInputAction: widget.textInputAction,
      obscureText: widget.obscureText,
      inputFormatters: widget.inputFormatters,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      enableInteractiveSelection: true,
      maxLines: widget.maxLines,
      minLines: widget.maxLines > 1 ? widget.maxLines : null,
      cursorWidth: 2.0,
      cursorHeight: widget.maxLines > 1 ? null : 18,
      // Strip Cupertino's built-in visual chrome — our outer container handles
      // bg/border/padding. Without these, you'd get a doubled border + extra
      // 6px padding around the text.
      decoration: null,
      padding: EdgeInsets.zero,
      // Use Cupertino's native placeholder (not a Stack overlay) — the overlay
      // Text widget was intercepting long-press/double-tap gestures on iOS so
      // selection + paste menu never reached the input. Discovered 2026-05-23
      // on physical iPhone — user could focus + type but not select/paste.
      placeholder: widget.hintText,
      placeholderStyle: hintStyle,
      // Explicit context menu builder — custom Cupertino-styled bar with
      // EXPLICIT colors so it renders correctly in dark mode without depending
      // on theme inheritance that was producing invisible buttons.
      contextMenuBuilder: dsTextContextMenu,
    );

    final children = <Widget>[];
    if (widget.prefix != null) {
      children.add(
        DefaultTextStyle.merge(
          style: DsText.body.copyWith(fontWeight: FontWeight.w500, height: 1.0, color: tokens.text3),
          child: widget.prefix!,
        ),
      );
      children.add(const SizedBox(width: 8));
    }
    // Field is wrapped only in Expanded — no Stack overlay. The hint is now
    // CupertinoTextField's native `placeholder` (above). This eliminates the
    // gesture-stealing Text overlay that broke iOS selection/paste menus.
    children.add(Expanded(child: field));
    if (widget.suffix != null) {
      children.add(const SizedBox(width: 8));
      children.add(
        IconTheme(
          data: IconThemeData(color: tokens.text3, size: 18),
          child: widget.suffix!,
        ),
      );
    }

    final container = Container(
      height: widget.maxLines > 1 ? null : 50,
      padding: widget.maxLines > 1
          ? const EdgeInsets.symmetric(horizontal: DsSpace.x4, vertical: DsSpace.x3h5)
          : const EdgeInsets.symmetric(horizontal: DsSpace.x4),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _isFocused ? tokens.accent : tokens.dividerStrong, width: _isFocused ? 1.0 : 0.5),
        boxShadow: _isFocused ? [DsShadow.ring(tokens.accentSoft, spread: 2)] : null,
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: children),
    );

    if (widget.label == null) return container;

    // VoiceOver reads the field with its label ("Name, text field") —
    // the label above it was a separate element (tech-debt 2.29).
    return MergeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: DsSpace.x1, bottom: DsSpace.x1h5),
            child: Text(
              widget.label!.toUpperCase(),
              semanticsLabel: widget.label,
              style: DsText.footnote.copyWith(fontWeight: FontWeight.w600, height: 1.0, color: tokens.text3),
            ),
          ),
          container,
        ],
      ),
    );
  }
}

/// The copy / paste bar of every text field, in the phone's language (it
/// was English everywhere — 2026-10-16 UI audit). Explicit colours so it
/// reads in dark mode too.
Widget dsTextContextMenu(BuildContext context, EditableTextState editableTextState) {
  final buttons = <Widget>[];
  final canPaste = editableTextState.pasteEnabled;
  final canSelectAll = editableTextState.selectAllEnabled;
  final canCopy = editableTextState.copyEnabled;
  if (canSelectAll) {
    buttons.add(
      CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5, vertical: DsSpace.x2),
        onPressed: () => editableTextState.selectAll(SelectionChangedCause.toolbar),
        child: Text(context.l10n.textSelectAll, style: DsTextArt.t14v2),
      ),
    );
  }
  if (editableTextState.cutEnabled) {
    buttons.add(
      CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5, vertical: DsSpace.x2),
        onPressed: () => editableTextState.cutSelection(SelectionChangedCause.toolbar),
        child: Text(context.l10n.textCut, style: DsTextArt.t14v2),
      ),
    );
  }
  if (canCopy) {
    buttons.add(
      CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5, vertical: DsSpace.x2),
        onPressed: () => editableTextState.copySelection(SelectionChangedCause.toolbar),
        child: Text(context.l10n.copy, style: DsTextArt.t14v2),
      ),
    );
  }
  if (canPaste) {
    buttons.add(
      CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: DsSpace.x3h5, vertical: DsSpace.x2),
        onPressed: () => editableTextState.pasteText(SelectionChangedCause.toolbar),
        child: Text(context.l10n.textPaste, style: DsTextArt.t14v2),
      ),
    );
  }
  if (buttons.isEmpty) return const SizedBox.shrink();
  // Wrap in a sized, positioned toolbar with bounded width.
  return CupertinoAdaptiveTextSelectionToolbar(
    anchors: editableTextState.contextMenuAnchors,
    children: [
      DecoratedBox(
        decoration: BoxDecoration(color: DsPalette.art1F1F22, borderRadius: BorderRadius.circular(10)),
        child: IntrinsicWidth(
          child: Row(mainAxisSize: MainAxisSize.min, children: buttons),
        ),
      ),
    ],
  );

}

/// A borderless text field for custom-drawn inputs (the chat composer,
/// search, group name, the 24 words). A bare `EditableText` had no
/// selection gestures and no menu — paste into the chat or the 24-word box
/// didn't work on a phone (2026-10-16 UI audit). Same parameters as
/// `EditableText` where they overlap.
class DsPlainField extends StatelessWidget {
  const DsPlainField({
    super.key,
    required this.controller,
    this.focusNode,
    this.style,
    this.cursorColor,
    this.backgroundCursorColor,
    this.maxLines = 1,
    this.minLines,
    this.keyboardType,
    this.textInputAction,
    this.textCapitalization = TextCapitalization.none,
    this.inputFormatters,
    this.onChanged,
    this.onSubmitted,
    this.onTapOutside,
    this.autofocus = false,
    this.autocorrect = true,
    this.contextMenuBuilder,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;

  /// The selection menu; [dsTextContextMenu] when null (the chat composer
  /// adds "Format", ADR-070).
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final TextStyle? style;
  final Color? cursorColor;

  /// Accepted for drop-in use; the platform draws the cursor background.
  final Color? backgroundCursorColor;
  final int? maxLines;
  final int? minLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final TextCapitalization textCapitalization;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TapRegionCallback? onTapOutside;
  final bool autofocus;
  final bool autocorrect;

  @override
  Widget build(BuildContext context) {
    // Selection handles and the menu live in an Overlay; the app always has
    // one (Navigator). A bare preview / test without it gets a plain field.
    if (Overlay.maybeOf(context) == null) {
      return EditableText(
        controller: controller,
        focusNode: focusNode ?? FocusNode(),
        style: style ?? const TextStyle(),
        cursorColor: cursorColor ?? DsTheme.of(context).accent,
        backgroundCursorColor: backgroundCursorColor ?? DsTheme.of(context).text4,
        maxLines: maxLines,
        minLines: minLines,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        textCapitalization: textCapitalization,
        inputFormatters: inputFormatters,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        onTapOutside: onTapOutside,
        autofocus: autofocus,
        autocorrect: autocorrect,
      );
    }
    return _field();
  }

  Widget _field() => CupertinoTextField(
    controller: controller,
    focusNode: focusNode,
    style: style,
    cursorColor: cursorColor,
    maxLines: maxLines,
    minLines: minLines,
    keyboardType: keyboardType ?? (maxLines == 1 ? TextInputType.text : TextInputType.multiline),
    textInputAction: textInputAction,
    textCapitalization: textCapitalization,
    inputFormatters: inputFormatters,
    onChanged: onChanged,
    onSubmitted: onSubmitted,
    onTapOutside: onTapOutside,
    autofocus: autofocus,
    autocorrect: autocorrect,
    decoration: null,
    padding: EdgeInsets.zero,
    contextMenuBuilder: contextMenuBuilder ?? dsTextContextMenu,
  );
}
