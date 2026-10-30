import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotube/models/metadata/metadata.dart';
import 'package:spotube/provider/metadata_plugin/core/auth.dart';
import 'package:spotube/provider/metadata_plugin/utils/family_paginated.dart';
import 'package:spotube/services/logger/logger.dart';

class MetadataPluginBrowseSectionItemsNotifier
    extends FamilyPaginatedAsyncNotifier<Object, String> {
  /// Section id -> last successful payload (first page only). Sections
  /// degrade to their last known content instead of vanishing when the
  /// plugin's request fails (e.g. a transient auth/network error) - a
  /// stale section is more useful than a missing one.
  static final Map<String, SpotubePaginationResponseObject<Object>>
      _lastGood = {};

  @override
  Future<SpotubePaginationResponseObject<Object>> fetch(
    int offset,
    int limit,
  ) async {
    try {
      final res = await (await metadataPlugin).browse.sectionItems(
            arg,
            limit: limit,
            offset: offset,
          );
      if (offset == 0) {
        _lastGood[arg] = res;
      }
      return res;
    } catch (e, stack) {
      AppLogger.reportError(e, stack);
      final stale = _lastGood[arg];
      if (stale != null && offset == 0) {
        return stale;
      }
      rethrow;
    }
  }

  @override
  build(arg) async {
    ref.watch(metadataPluginAuthenticatedProvider);
    return await fetch(0, 20);
  }
}

final metadataPluginBrowseSectionItemsProvider = AsyncNotifierProviderFamily<
    MetadataPluginBrowseSectionItemsNotifier,
    SpotubePaginationResponseObject<Object>,
    String>(
  () => MetadataPluginBrowseSectionItemsNotifier(),
);
