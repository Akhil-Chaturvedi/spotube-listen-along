import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';
import 'package:spotube/services/logger/logger.dart';

class MetadataPluginBrowseSectionsNotifier
    extends PaginatedAsyncNotifier<SpotubeBrowseSectionObject<Object>> {
  /// Throttle for [refreshIfStale] so UI visibility triggers can call it
  /// freely without hammering the plugin.
  DateTime? _lastRefreshIfStaleAt;

  @override
  Future<SpotubePaginationResponseObject<SpotubeBrowseSectionObject<Object>>>
      fetch(
    int offset,
    int limit,
  ) async {
    try {
      return await (await metadataPlugin).browse.sections(
            limit: limit,
            offset: offset,
          );
    } catch (e, stack) {
      // The plugin's sections() may fail for many reasons (buddylist endpoint
      // down, token expired, network error). Log it but don't crash the entire
      // Home tab — return an empty page so the user still sees the app.
      AppLogger.reportError(e, stack);
      return SpotubePaginationResponseObject(
        limit: limit,
        nextOffset: null,
        total: 0,
        hasMore: false,
        items: [],
      );
    }
  }

  /// Generic "never show stale sections" entry point. Any UI surface that
  /// becomes visible (Home tab mounted, app resumed, etc.) may call this;
  /// it re-fetches the first page only when the current data is older than
  /// [maxAge], and DEGRADES to the previously displayed items when the
  /// refresh fails or comes back empty. At most one actual refresh per
  /// maxAge window regardless of how often it is called.
  Future<void> refreshIfStale({
    Duration maxAge = const Duration(seconds: 15),
  }) async {
    final data = state.asData;
    if (data == null) return; // initial load / error state: leave as-is
    final now = DateTime.now();
    final last = _lastRefreshIfStaleAt;
    if (last != null && now.difference(last) < maxAge) return;
    _lastRefreshIfStaleAt = now;
    try {
      final page = await fetch(0, 20);
      // Degrade gracefully: an empty refresh (plugin error) must never wipe
      // content the user is looking at.
      if (page.items.isNotEmpty || data.value.items.isEmpty) {
        state = AsyncData(page);
      }
    } catch (_) {
      // fetch() already degrades internally; never let a refresh kill the UI.
    }
  }

  @override
  build() async {
    // Await auth resolution before fetching. Without this, build() races ahead
    // of the plugin's async token restore and the request is sent with a null
    // token ("Bearer null"), producing a 401 on every startup.
    final isAuthenticated =
        await ref.watch(metadataPluginAuthenticatedProvider.future);

    if (!isAuthenticated) {
      return SpotubePaginationResponseObject(
        limit: 20,
        nextOffset: null,
        total: 0,
        hasMore: false,
        items: [],
      );
    }

    // NOTE: no periodic timer here. A fixed-interval refresh caused constant
    // re-fetching (and connection churn) on the home screen. Dynamic sections
    // instead refresh on demand: a plugin calls Plugin.requestRefresh(), which
    // invalidates this provider (see metadata_plugin_provider.dart).
    return await fetch(0, 20);
  }
}

final metadataPluginBrowseSectionsProvider = AsyncNotifierProvider<
    MetadataPluginBrowseSectionsNotifier,
    SpotubePaginationResponseObject<SpotubeBrowseSectionObject<Object>>>(
  () => MetadataPluginBrowseSectionsNotifier(),
);
