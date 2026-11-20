// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';

Duration motionDuration(BuildContext context, [int milliseconds = 180]) =>
    MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Duration(milliseconds: milliseconds);

/// An indeterminate wait state that respects the system's reduced-motion
/// preference instead of leaving Material's repeating progress animation active.
class WorkspaceProgress extends StatelessWidget {
  const WorkspaceProgress({
    super.key,
    required this.label,
    this.linear = false,
  });

  final String label;
  final bool linear;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      final status = Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.hourglass_empty_rounded,
            size: 18, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 8),
        Flexible(child: Text(label)),
      ]);
      if (linear) {
        return Semantics(liveRegion: true, child: status);
      }
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Semantics(liveRegion: true, child: status),
      ]);
    }
    if (linear) {
      return Semantics(
          liveRegion: true,
          child: LinearProgressIndicator(semanticsLabel: label));
    }
    return Semantics(
      liveRegion: true,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(label),
      ]),
    );
  }
}

/// Pointer feedback without taking over the child's click or keyboard handling.
class ActionMotion extends StatefulWidget {
  const ActionMotion({super.key, required this.child, this.enabled});
  final Widget child;

  /// Overrides automatic detection for interactive children hidden by wrappers.
  final bool? enabled;

  @override
  State<ActionMotion> createState() => _ActionMotionState();
}

class _ActionMotionState extends State<ActionMotion> {
  bool _hover = false;
  bool _pressed = false;

  bool get _enabled {
    if (widget.enabled != null) return widget.enabled!;
    final child = widget.child;
    if (child is ButtonStyleButton) {
      return child.onPressed != null || child.onLongPress != null;
    }
    if (child is ChoiceChip) return child.onSelected != null;
    return true;
  }

  @override
  void didUpdateWidget(covariant ActionMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_enabled) {
      _hover = false;
      _pressed = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    final enabled = _enabled;
    return MouseRegion(
      onEnter: (_) {
        if (enabled) setState(() => _hover = true);
      },
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: Listener(
        onPointerDown: (_) {
          if (enabled) setState(() => _pressed = true);
        },
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: motionDuration(context, 130),
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(
              0, enabled && !reduce && _hover && !_pressed ? -2 : 0, 0),
          child: AnimatedScale(
            scale: enabled && !reduce && _pressed ? .985 : 1,
            duration: motionDuration(context, 90),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class WorkspaceEntry extends StatelessWidget {
  const WorkspaceEntry({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: motionDuration(context, 260),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
            offset: Offset(0, 8 * (1 - value)), child: child),
      ),
      child: child,
    );
  }
}
