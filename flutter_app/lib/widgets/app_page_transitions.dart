import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;

/// Consistent route motion that honors the OS reduced-motion preference.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final platform = Theme.of(context).platform;
    if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
      const cupertino = CupertinoPageTransitionsBuilder();
      return cupertino.buildTransitions(
        route,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }
    final curved = animation.drive(CurveTween(curve: Curves.easeOutCubic));
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: curved
            .drive(Tween(begin: const Offset(0, 0.025), end: Offset.zero)),
        child: child,
      ),
    );
  }
}

const appPageTransitionsTheme = PageTransitionsTheme(builders: {
  TargetPlatform.android: AppPageTransitionsBuilder(),
  TargetPlatform.fuchsia: AppPageTransitionsBuilder(),
  TargetPlatform.linux: AppPageTransitionsBuilder(),
  TargetPlatform.windows: AppPageTransitionsBuilder(),
  TargetPlatform.iOS: AppPageTransitionsBuilder(),
  TargetPlatform.macOS: AppPageTransitionsBuilder(),
});
