import 'package:path/path.dart' as p;

import '../../core/podcast_models.dart';
import 'podcast_urls.dart';

class PodcastDownloadLocator {
  const PodcastDownloadLocator();

  PodcastDownloadLocation resolve({
    required String jobId,
    required PodcastEpisode episode,
    required String managedRoot,
  }) {
    final extension = episode.mediaExtension;
    final shortId = PodcastEpisodeId.parse(episode.id).shortFileComponent;
    final fileName =
        '${sanitizePodcastFileName(episode.title)} [$shortId].$extension';
    return PodcastDownloadLocation(
      kind: PodcastDownloadLocationKind.managedCache,
      directory: p.join(managedRoot, 'podcasts', jobId),
      fileName: fileName,
    );
  }
}
