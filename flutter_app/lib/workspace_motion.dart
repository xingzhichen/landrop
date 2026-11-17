// ignore_for_file: deprecated_member_use
import 'package:flutter/material.dart';

Duration motionDuration(BuildContext context, [int milliseconds = 180]) =>
    MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Duration(milliseconds: milliseconds);

/// Pointer feedback without taking over the child's click or keyboard handling.
class ActionMotion extends StatefulWidget {
  const ActionMotion({super.key, required this.child});
  final Widget child;
  @override
  State<ActionMotion> createState() => _ActionMotionState();
}

class _ActionMotionState extends State<ActionMotion> {
  bool _hover = false;
  bool _pressed = false;
  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: Listener(
        onPointerDown: (_) => setState(() => _pressed = true),
        onPointerUp: (_) => setState(() => _pressed = false),
        onPointerCancel: (_) => setState(() => _pressed = false),
        child: AnimatedContainer(
          duration: motionDuration(context, 130),
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(
              0, !reduce && _hover && !_pressed ? -2 : 0, 0),
          child: AnimatedScale(
            scale: !reduce && _pressed ? .985 : 1,
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
