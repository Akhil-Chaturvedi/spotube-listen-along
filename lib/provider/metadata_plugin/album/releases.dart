import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/paginated.dart';

class MetadataPluginAlbumReleasesNotifier
    extends PaginatedAsyncNotifier<SpotubeSimpleAlbumObject> {
  @override
  Future<SpotubePaginationResponseObject<SpotubeSimpleAlbumObject>> fetch(
    int offset,
    int limit,
  ) async {
    return await (await metadataPlugin)
        .album
        .releases(limit: limit, offset: offset);
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
    return await fetch(0, 20);
  }
}

final metadataPluginAlbumReleasesProvider = AsyncNotifierProvider<
    MetadataPluginAlbumReleasesNotifier,
    SpotubePaginationResponseObject<SpotubeSimpleAlbumObject>>(
  () => MetadataPluginAlbumReleasesNotifier(),
);
