import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';
import 'package:spotube/services/logger/logger.dart';

class MetadataPluginBrowseSectionsNotifier
    extends PaginatedAsyncNotifier<SpotubeBrowseSectionObject<Object>> {
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
