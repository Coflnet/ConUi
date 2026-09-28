import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'l10n/gen/app_localizations.dart';
import 'services/app_settings_service.dart';
import 'services/auth_service.dart';
import 'services/database_service.dart';
import 'services/sync_service.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dbService = DatabaseService();
  await dbService.initialize();

  final authService = AuthService();
  await authService.initialize();

  final syncService = SyncService(dbService, authService);

  final appSettings = AppSettingsService();
  await appSettings.initialize();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: dbService),
        ChangeNotifierProvider.value(value: authService),
        ChangeNotifierProvider.value(value: syncService),
        ChangeNotifierProvider.value(value: appSettings),
      ],
      child: const RelationshipManagerApp(),
    ),
  );
}

class RelationshipManagerApp extends StatelessWidget {
  const RelationshipManagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final appSettings = context.watch<AppSettingsService>();
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      locale: appSettings.languageOverride,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // English first, not AppLocalizations.supportedLocales (which lists
      // them alphabetically, German first): Flutter's default resolution
      // falls back to supportedLocales.first for a device language that
      // matches neither, and that fallback must be English, per the
      // brief ("German for de*, English otherwise").
      supportedLocales: const [Locale('en'), Locale('de')],
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // Roboto itself is bundled as an asset (see assets/fonts/README.md),
        // so Material's default "Roboto" family resolves locally; this
        // fallback only covers the rare glyph Roboto itself doesn't have
        // (e.g. certain symbols/arrows), so web never needs to reach
        // fonts.gstatic.com for either.
        fontFamilyFallback: const ['Noto Sans Symbols'],
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          filled: true,
        ),
      ),
      darkTheme: ThemeData(
        fontFamilyFallback: const ['Noto Sans Symbols'],
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          filled: true,
        ),
      ),
      home: Consumer<AuthService>(
        builder: (context, authService, _) {
          if (authService.isAuthenticated || authService.continuedWithoutAccount) {
            return const HomeScreen();
          }
          return const LoginScreen();
        },
      ),
    );
  }
}
