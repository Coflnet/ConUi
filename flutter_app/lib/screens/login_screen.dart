import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import '../l10n/gen/app_localizations.dart';
import '../services/auth_service.dart';
import '../services/sync_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _userIdController = TextEditingController(text: 'testuser');
  final _nameController = TextEditingController(text: 'Test User');
  final _emailController = TextEditingController(text: 'test@example.com');
  final _passwordController = TextEditingController(text: 'password123');
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Auto-login in debug/development mode for testing
    if (kDebugMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _autoLogin();
      });
    }
  }

  Future<void> _autoLogin() async {
    // Wait a moment for the UI to be ready
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      _login();
    }
  }

  @override
  void dispose() {
    _userIdController.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final authService = context.read<AuthService>();
    final syncService = context.read<SyncService>();

    final success = await authService.devLogin(
      _userIdController.text,
      name: _nameController.text,
      email: _emailController.text,
    );

    if (success) {
      // Initialize encryption with password
      syncService.initializeEncryption(_passwordController.text);

      // Don't sync on login screen - let home screen handle it
      // await syncService.syncOnOpen();
    } else {
      if (mounted) {
        setState(() {
          _error = AppLocalizations.of(context).loginFailed;
        });
      }
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _signIn() async {
    setState(() => _isLoading = true);
    final success = await context
        .read<AuthService>()
        .signIn(locale: Localizations.localeOf(context).languageCode);
    if (!mounted) return;
    setState(() => _isLoading = false);
    if (success && Navigator.canPop(context)) Navigator.pop(context);
  }

  Future<void> _continueWithoutAccount() async {
    final authService = context.read<AuthService>();
    await authService.continueWithoutAccount();
    // No navigation call needed: main.dart's root Consumer<AuthService>
    // rebuilds into HomeScreen as soon as continuedWithoutAccount is true.
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final auth = context.watch<AuthService>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.people_outline,
                    size: 80,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l10n.loginTitle,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.loginTagline,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Colors.grey,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 48),
                  if (auth.signInFailed || auth.signInUnavailable) ...[
                    Text(
                        auth.signInUnavailable
                            ? l10n.loginAccountUnavailable
                            : l10n.loginAccountFailed,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 16),
                  ],
                  FilledButton.icon(
                    key: const Key('account-sign-in'),
                    onPressed: _isLoading || auth.signInRetrySeconds > 0
                        ? null
                        : _signIn,
                    icon: const Icon(Icons.login),
                    label: Text(_isLoading
                        ? l10n.loginButtonBusy
                        : auth.signInRetrySeconds > 0
                            ? l10n.loginAccountRetryCountdown(
                                auth.signInRetrySeconds)
                            : l10n.loginAccountButton),
                  ),
                  const SizedBox(height: 12),
                  // Development credentials only reach the debug endpoint.
                  if (kDebugMode) ...[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.loginDevSectionTitle,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _userIdController,
                              decoration: InputDecoration(
                                labelText: l10n.loginUserIdLabel,
                                prefixIcon: const Icon(Icons.person),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _nameController,
                              decoration: InputDecoration(
                                labelText: l10n.loginNameLabel,
                                prefixIcon: const Icon(Icons.badge),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _emailController,
                              decoration: InputDecoration(
                                labelText: l10n.loginEmailLabel,
                                prefixIcon: const Icon(Icons.email),
                              ),
                              keyboardType: TextInputType.emailAddress,
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _passwordController,
                              decoration: InputDecoration(
                                labelText: l10n.loginPasswordLabel,
                                prefixIcon: const Icon(Icons.lock),
                                helperText: l10n.loginPasswordHelper,
                              ),
                              obscureText: true,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_error != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onErrorContainer,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    FilledButton.icon(
                      onPressed: _isLoading ? null : _login,
                      icon: _isLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.login),
                      label: Text(
                          _isLoading ? l10n.loginButtonBusy : l10n.loginButton),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _isLoading ? null : _continueWithoutAccount,
                      child: Text(l10n.loginContinueWithoutAccount),
                    ),
                  ] else
                    OutlinedButton(
                      onPressed: _continueWithoutAccount,
                      child: Text(l10n.loginContinueWithoutAccount),
                    ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.loginContinueExplainer,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  if (kDebugMode) ...[
                    const SizedBox(height: 16),
                    Text(
                      l10n.loginDevNote,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey,
                          ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
