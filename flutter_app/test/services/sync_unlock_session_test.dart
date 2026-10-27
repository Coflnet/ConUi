import 'package:flutter_test/flutter_test.dart';
import 'package:relationship_manager/services/auth_service.dart';
import 'package:relationship_manager/services/encryption_service.dart';
import 'package:relationship_manager/services/sync_service.dart';

import '../support/test_database.dart';

class _Auth extends AuthService {
  String id = 'first';
  String salt = 'first-salt';
  @override
  String get userId => id;
  @override
  String get encryptionSalt => salt;
  @override
  bool get isAuthenticated => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final change in ['account', 'salt', 'lock']) {
    test('$change during key derivation cannot publish an unlocked key', () async {
      final auth = _Auth();
      final sync = SyncService(createTestDatabaseService(), auth);
      final unlocking = sync.initializeEncryption('synthetic-password');
      expect(sync.isUnlocked, isFalse);
      if (change == 'account') auth.id = 'second';
      if (change == 'salt') auth.salt = 'second-salt';
      if (change == 'lock') sync.lockEncryption();
      await expectLater(unlocking, throwsStateError);
      expect(sync.isUnlocked, isFalse);
      expect(sync.needsEncryptionPassword, isTrue);
      expect(EncryptionService.instance, isNull);
    });
  }
}
