import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class IseCredentials {
  const IseCredentials({
    required this.appId,
    required this.apiKey,
    required this.apiSecret,
  });

  final String appId;
  final String apiKey;
  final String apiSecret;

  IseCredentials normalized() => IseCredentials(
        appId: appId.trim(),
        apiKey: apiKey.trim(),
        apiSecret: apiSecret.trim(),
      );

  bool get isComplete {
    final value = normalized();
    return value.appId.isNotEmpty &&
        value.apiKey.isNotEmpty &&
        value.apiSecret.isNotEmpty;
  }
}

abstract interface class IseCredentialStore {
  Future<IseCredentials?> read();
  Future<void> write(IseCredentials credentials);
  Future<void> clear();
}

final class SecureIseCredentialStore implements IseCredentialStore {
  const SecureIseCredentialStore(this.storage);

  static const _appIdKey = 'xfyun_ise_app_id';
  static const _apiKeyKey = 'xfyun_ise_api_key';
  static const _apiSecretKey = 'xfyun_ise_api_secret';

  final FlutterSecureStorage storage;

  @override
  Future<IseCredentials?> read() async {
    final values = await Future.wait([
      storage.read(key: _appIdKey),
      storage.read(key: _apiKeyKey),
      storage.read(key: _apiSecretKey),
    ]);
    final credentials = IseCredentials(
      appId: values[0] ?? '',
      apiKey: values[1] ?? '',
      apiSecret: values[2] ?? '',
    ).normalized();
    return credentials.isComplete ? credentials : null;
  }

  @override
  Future<void> write(IseCredentials credentials) async {
    final value = credentials.normalized();
    if (!value.isComplete) {
      throw ArgumentError('讯飞配置不完整');
    }
    await Future.wait([
      storage.write(key: _appIdKey, value: value.appId),
      storage.write(key: _apiKeyKey, value: value.apiKey),
      storage.write(key: _apiSecretKey, value: value.apiSecret),
    ]);
  }

  @override
  Future<void> clear() => Future.wait([
        storage.delete(key: _appIdKey),
        storage.delete(key: _apiKeyKey),
        storage.delete(key: _apiSecretKey),
      ]);
}

final flutterSecureStorageProvider = Provider<FlutterSecureStorage>(
  (_) => const FlutterSecureStorage(),
);

final iseCredentialStoreProvider = Provider<IseCredentialStore>(
  (ref) => SecureIseCredentialStore(ref.watch(flutterSecureStorageProvider)),
);
