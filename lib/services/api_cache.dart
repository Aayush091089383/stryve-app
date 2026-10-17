class ApiCache {
  static final _cache = <String, _CacheEntry>{};
  static const _ttl = Duration(minutes: 5);

  static String? get(String key) {
    final entry = _cache[key];
    if (entry == null) return null;

    if (DateTime.now().isAfter(entry.expiry)) {
      _cache.remove(key);
      return null;
    }

    return entry.data;
  }

  static void set(String key, String data) {
    _cache[key] = _CacheEntry(
      data: data,
      expiry: DateTime.now().add(_ttl),
    );
  }

  static void clear() {
    _cache.clear();
  }
}

class _CacheEntry {
  final String data;
  final DateTime expiry;

  _CacheEntry({required this.data, required this.expiry});
}
