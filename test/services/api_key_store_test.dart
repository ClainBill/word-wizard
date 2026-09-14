import 'package:flutter_test/flutter_test.dart';
import 'package:word_wizard/services/api_key_store.dart';

void main() {
  test('looksLikeKey accepts key-shaped tokens and nothing else', () {
    expect(ApiKeyStore.looksLikeKey('sk-proj-abcDEF123_456-789xyzABCDEFGHIJ'), isTrue);
    expect(ApiKeyStore.looksLikeKey('  sk-proj-abcDEF123_456-789xyzABCDEFGHIJ\n'), isTrue);
    expect(ApiKeyStore.looksLikeKey('sk-short'), isFalse);
    expect(ApiKeyStore.looksLikeKey('The Ineffable Charm of Old Dictionaries'), isFalse);
    expect(ApiKeyStore.looksLikeKey('sk-abc\ndef' * 4), isFalse);
    expect(ApiKeyStore.looksLikeKey(''), isFalse);
  });

  test('mask keeps only the prefix and last four characters', () {
    expect(ApiKeyStore.mask('sk-proj-abcdefghijklmnop4RsA'), 'sk-…4RsA');
    expect(ApiKeyStore.mask('short'), '••••');
  });

  test('validate refuses non-keys without touching the network', () async {
    expect(await ApiKeyStore.validate(''), 'Enter a key first.');
    expect(await ApiKeyStore.validate('not a key at all'), 'That doesn\'t look like an API key.');
  });
}
