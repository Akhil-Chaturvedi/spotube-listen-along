import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';

/// How often the Browse sections are re-fetched while the app is open.
///
/// Sections are otherwise fetched exactly once per session, which means
/// dynamic sections (e.g. a plugin's "Friend Activity") never update. A modest
/// interval keeps them fresh without hammering the metadata provider.
const _browseSectionsRefreshInterval = Duration(seconds: 30);

class MetadataPluginBrowseSectionsNotifier
    extends PaginatedAsyncNotifier<SpotubeBrowseSectionObject<Object>> {
  @override
  Future<SpotubePaginationResponseObject<SpotubeBrowseSectionObject<Object>>>
      fetch(
    int offset,
    int limit,
  ) async {
    return await (await metadataPlugin).browse.sections(
          limit: limit,
          offset: offset,
        );
  }

  @override
  build() async {
    // Await auth resolution before fetching. Without this, build() races ahead
    // of the plugin's async token restore and the request is sent with a null
    // token ("Bearer null"), producing a 401 on every startup.
    final isAuthenticated =
        await ref.watch(metadataPluginAuthenticatedProvider.future);

    // Only poll while authenticated; before login the plugin has no token and
    // every request would 401. The notifier rebuilds when auth state changes,
    // which starts/stops the timer accordingly.
    if (isAuthenticated) {
      final timer = Timer.periodic(_browseSectionsRefreshInterval, (_) {
        ref.invalidateSelf();
      });
      ref.onDispose(timer.cancel);
    } else {
      return SpotubePaginationResponseObject(
        limit: 20,
        nextOffset: null,
        total: 0,
        hasMore: false,
        items: [],
      );
    }

    return await fetch(0, 20);
  }
}

final metadataPluginBrowseSectionsProvider = AsyncNotifierProvider<
    MetadataPluginBrowseSectionsNotifier,
    SpotubePaginationResponseObject<SpotubeBrowseSectionObject<Object>>>(
  () => MetadataPluginBrowseSectionsNotifier(),
);
