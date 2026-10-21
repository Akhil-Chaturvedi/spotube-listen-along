part of 'metadata.dart';

@freezed
class SpotubeFullPlaylistObject with _$SpotubeFullPlaylistObject {
  factory SpotubeFullPlaylistObject({
    required String id,
    required String name,
    required String description,
    required String externalUri,
    required SpotubeUserObject owner,
    @Default([]) List<SpotubeImageObject> images,
    @Default([]) List<SpotubeUserObject> collaborators,
    @Default(false) bool collaborative,
    @Default(false) bool public,
  }) = _SpotubeFullPlaylistObject;

  factory SpotubeFullPlaylistObject.fromJson(Map<String, dynamic> json) =>
      _$SpotubeFullPlaylistObjectFromJson(json);
}

@freezed
class SpotubeSimplePlaylistObject with _$SpotubeSimplePlaylistObject {
  factory SpotubeSimplePlaylistObject({
    required String id,
    required String name,
    required String description,
    required String externalUri,
    required SpotubeUserObject owner,
    @Default([]) List<SpotubeImageObject> images,
    /// Generic marker for metadata plugins: this card represents a *live*
    /// entity that is playing elsewhere (e.g. a friend's session). Hosts may
    /// offer "sync/mirror" behavior on such cards. Optional and ignored by
    /// plugins that don't set it.
    @Default(false) bool isLive,
    /// Generic timestamp (epoch ms) of when this entity was last active.
    /// Used to render a relative-time / "now" label on cards. Optional.
    int? lastActiveAt,
  }) = _SpotubeSimplePlaylistObject;

  factory SpotubeSimplePlaylistObject.fromJson(Map<String, dynamic> json) =>
      _$SpotubeSimplePlaylistObjectFromJson(json);
}
