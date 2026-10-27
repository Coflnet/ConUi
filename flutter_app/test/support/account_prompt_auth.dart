import 'package:relationship_manager/services/auth_service.dart';

/// Keeps account prompt tests offline and records explicit auth choices.
class AccountPromptAuth extends AuthService {
  final choices = <bool>[];
  Future<void> Function()? beforeAttempt;

  @override
  Future<bool> signIn(
      {String locale = 'de',
      bool createAccount = false,
      String? identityProvider}) async {
    await beforeAttempt?.call();
    choices.add(createAccount);
    signInFailed = true;
    return false;
  }
}
