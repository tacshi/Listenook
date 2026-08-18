import 'contracts.dart';
import 'models.dart';

typedef ModelDownloadProgress =
    void Function(int downloadedBytes, int totalBytes);

abstract final class CoreMlSpeechRuntimeSupport {
  static bool isSupported({
    required bool isMacOS,
    required bool isArm64,
    required String operatingSystemVersion,
  }) {
    if (!isMacOS || !isArm64) return false;
    final match = RegExp(
      r'(?:Version\s+|macOS\s+)(\d+)',
      caseSensitive: false,
    ).firstMatch(operatingSystemVersion);
    return (int.tryParse(match?.group(1) ?? '') ?? 0) >= 15;
  }
}

class LocalModelFile {
  const LocalModelFile({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
  });

  final String path;
  final int sizeBytes;
  final String sha256;
}

class LocalModelDescriptor {
  const LocalModelDescriptor({
    required this.id,
    required this.displayName,
    required this.repository,
    required this.revision,
    required this.files,
  });

  final String id;
  final String displayName;
  final String repository;
  final String revision;
  final List<LocalModelFile> files;

  int get sizeBytes => files.fold(0, (total, file) => total + file.sizeBytes);

  Uri downloadUriFor(LocalModelFile file) => Uri.https(
    'huggingface.co',
    '/$repository/resolve/$revision/${file.path}',
    const {'download': 'true'},
  );
}

abstract final class LocalSpeechModels {
  static const mossDiarizeCoreMlInt8 = LocalModelDescriptor(
    id: 'moss-transcribe-diarize-0.9b-coreml-int8',
    displayName: 'MOSS transcription',
    repository: 'aufklarer/MOSS-Transcribe-Diarize-0.9B-CoreML-INT8',
    revision: '1cd68cfc84a26f0df95ba0868982d2c185839b62',
    files: [
      LocalModelFile(
        path: 'config.json',
        sizeBytes: 844,
        sha256:
            '0bedeebf2874b14940d6182a149c3e106adad1198450eeae8c55a44150c73c42',
      ),
      LocalModelFile(
        path: 'audio_encoder.mlmodelc/metadata.json',
        sizeBytes: 1841,
        sha256:
            'a7c3fe71682a3aafc0d282bc71824092bde4d69b81f400bc8c16b9c3a556c21a',
      ),
      LocalModelFile(
        path: 'audio_encoder.mlmodelc/model.mil',
        sizeBytes: 272486,
        sha256:
            '468f9ba7bf4530320144c1acfd4c64985539660f6273dc2f276129a24d2ed614',
      ),
      LocalModelFile(
        path: 'audio_encoder.mlmodelc/coremldata.bin',
        sizeBytes: 329,
        sha256:
            'd866c92c5fa0f42e78c34e94da40fea00c5daa9b93e0d012795c0eb35d5bc04e',
      ),
      LocalModelFile(
        path: 'audio_encoder.mlmodelc/weights/weight.bin',
        sizeBytes: 624952768,
        sha256:
            '44ec78b8f543db6ef3facafeb044e443e7c449f3a84f803944c2e8bcd43b4c89',
      ),
      LocalModelFile(
        path: 'decoder/config.json',
        sizeBytes: 1261,
        sha256:
            '4043dff653976e44fad480de5f92c9b16c519e2560e092d310d4f0010c8d94ff',
      ),
      LocalModelFile(
        path: 'decoder/decoder.mlmodelc/metadata.json',
        sizeBytes: 39418,
        sha256:
            'e632a67e70f4b674510f80d5a6fdf718ea9ffd33149e816128ebb887d0824b9e',
      ),
      LocalModelFile(
        path: 'decoder/decoder.mlmodelc/model.mil',
        sizeBytes: 751282,
        sha256:
            'e00406cefded8c35715a2d19e0e0b910b4d3b285a67805c94a362ce5c0d3b8f7',
      ),
      LocalModelFile(
        path: 'decoder/decoder.mlmodelc/coremldata.bin',
        sizeBytes: 2154,
        sha256:
            '3a746712824b2ea02a0978681098d28008aa4fd4784f554941752d7c21c63342',
      ),
      LocalModelFile(
        path: 'decoder/decoder.mlmodelc/weights/weight.bin',
        sizeBytes: 633713600,
        sha256:
            'd1d9b4e9879b7971034bbf7ea4d6d8c6cd5078c0acf87928dd079aab6bcce140',
      ),
      LocalModelFile(
        path: 'processor_config.json',
        sizeBytes: 292,
        sha256:
            'a978c2dd54a65b576c3dae4b654fe9bcbac1184c6db2df0afb2c90fcdc872ae7',
      ),
      LocalModelFile(
        path: 'preprocessor_config.json',
        sizeBytes: 315,
        sha256:
            'ba2e601484abc80f4cded977f9a4fd4a53175b7d35c2f2511f0cfc3a32ad2499',
      ),
      LocalModelFile(
        path: 'generation_config.json',
        sizeBytes: 107,
        sha256:
            'e53a4b3ce4f944230cf1ca8fed0c42f4ff0d8c1443eaf98b5315d987334dd9e4',
      ),
      LocalModelFile(
        path: 'tokenizer.json',
        sizeBytes: 11423222,
        sha256:
            'bcf03774334462d6e34b5005cb11120a62275f146ee2953e68731ecdbce84fbb',
      ),
      LocalModelFile(
        path: 'tokenizer_config.json',
        sizeBytes: 503,
        sha256:
            '61d04c96104177240688396655ae3f7cf38ce2ea036db867a1d2b6883e27c3d5',
      ),
    ],
  );

  static const qwen3ForcedAlignerCoreMlInt8 = LocalModelDescriptor(
    id: 'qwen3-forced-aligner-0.6b-coreml-int8',
    displayName: 'Qwen3 word alignment — INT8',
    repository: 'aufklarer/Qwen3-ForcedAligner-0.6B-CoreML-INT8',
    revision: 'ac27c13a9dae935e7d478b996d89d94ff617e3ca',
    files: [
      LocalModelFile(
        path: 'config.json',
        sizeBytes: 233,
        sha256:
            '890e1c7cb7fbea843bb49defc259901a7a9d40a6211f06bf936b60669c602eed',
      ),
      LocalModelFile(
        path: 'audio_encoder.mlmodelc/metadata.json',
        sizeBytes: 2743,
        sha256:
            '9fe721386e8d4e4c82a6606def25442cd2bd20940920d43f32ae6dbc639ed840',
      ),
      LocalModelFile(
        path: 'audio_encoder.mlmodelc/model.mil',
        sizeBytes: 1380783,
        sha256:
            '2524ebe9480aef7c4d94c069c9b6b70e56722bb5ff00af98b633648c604dc901',
      ),
      LocalModelFile(
        path: 'audio_encoder.mlmodelc/coremldata.bin',
        sizeBytes: 376,
        sha256:
            'd310aae19a7b4bb18c5a9dbbeca9a4afc44062b3b28ef2df72bc3c273b39597e',
      ),
      LocalModelFile(
        path: 'audio_encoder.mlmodelc/weights/weight.bin',
        sizeBytes: 317035136,
        sha256:
            '7b4eddd9b588c002922922840086d08a7b195a6932774c506dc2d4cdc94a1b9b',
      ),
      LocalModelFile(
        path: 'embed_tokens.fp16.bin',
        sizeBytes: 311427072,
        sha256:
            'a6968a6f3a6520111cf9288239a09e766cdebba9067c43e59ef06c6aac8e0512',
      ),
      LocalModelFile(
        path: 'text_decoder.mlmodelc/metadata.json',
        sizeBytes: 2028,
        sha256:
            '7a4d314e8d69402a9c907c751e2e02545aaab72efaee825067bb3ee01d998b63',
      ),
      LocalModelFile(
        path: 'text_decoder.mlmodelc/model.mil',
        sizeBytes: 769149,
        sha256:
            '33ace10a29a73123eff4042c8df85b65c6af051019bfffb7a9dce1f5a0907205',
      ),
      LocalModelFile(
        path: 'text_decoder.mlmodelc/coremldata.bin',
        sizeBytes: 323,
        sha256:
            '147c6ed553d4ebb7ff9f1cc358416051a08e92a90d94f63c63f1bf8aaa5d96e2',
      ),
      LocalModelFile(
        path: 'text_decoder.mlmodelc/weights/weight.bin',
        sizeBytes: 446498960,
        sha256:
            '083cfeabb070794b7745694564f0154aa4329020c7eb344aff3406f348b25e3f',
      ),
      LocalModelFile(
        path: 'vocab.json',
        sizeBytes: 2776833,
        sha256:
            'ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910',
      ),
      LocalModelFile(
        path: 'merges.txt',
        sizeBytes: 1671853,
        sha256:
            '8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5',
      ),
      LocalModelFile(
        path: 'tokenizer_config.json',
        sizeBytes: 12666,
        sha256:
            '3ab80063f8511deb9566e6ad438d17b7a6277fcffd52d92854112f19d36bd81c',
      ),
    ],
  );

  static const qwen3ForcedAlignerCoreMlFp16 = LocalModelDescriptor(
    id: 'qwen3-forced-aligner-0.6b-coreml-fp16',
    displayName: 'Qwen3 word alignment — FP16',
    repository: 'aufklarer/Qwen3-ForcedAligner-0.6B-CoreML-FP16',
    revision: '04ca8c28f641b9e32a0ac8d1edd3cdec83f22159',
    files: [
      LocalModelFile(
        path: 'config.json',
        sizeBytes: 236,
        sha256:
            'fe0bcf6b20f2f24bd43868447ff12289260b668ad50cabcdafc74dbd8a4d0bf5',
      ),
      LocalModelFile(
        path: 'audio_encoder.mlmodelc/metadata.json',
        sizeBytes: 2673,
        sha256:
            '12eb3e1b047e9d0371b8f8044a339b826558e26890a96cd96f4f90abd6f226e6',
      ),
      LocalModelFile(
        path: 'audio_encoder.mlmodelc/model.mil',
        sizeBytes: 1345241,
        sha256:
            'fdc48cc61713681cea0e9d0cbe28f35a54f6a7fb1d47919e714c0439c69f3594',
      ),
      LocalModelFile(
        path: 'audio_encoder.mlmodelc/coremldata.bin',
        sizeBytes: 376,
        sha256:
            'd310aae19a7b4bb18c5a9dbbeca9a4afc44062b3b28ef2df72bc3c273b39597e',
      ),
      LocalModelFile(
        path: 'audio_encoder.mlmodelc/weights/weight.bin',
        sizeBytes: 633519616,
        sha256:
            '8a462623acd5c5112b509ed16fcff9444d3082e968f5a5f683ce6c1c5aa72255',
      ),
      LocalModelFile(
        path: 'embed_tokens.fp16.bin',
        sizeBytes: 311427072,
        sha256:
            'a6968a6f3a6520111cf9288239a09e766cdebba9067c43e59ef06c6aac8e0512',
      ),
      LocalModelFile(
        path: 'text_decoder.mlmodelc/metadata.json',
        sizeBytes: 1958,
        sha256:
            'd99f2802468256474eedcafcb97886f682ba5e4e51d20b55ec84f702edc7309c',
      ),
      LocalModelFile(
        path: 'text_decoder.mlmodelc/model.mil',
        sizeBytes: 720032,
        sha256:
            'fe12a4439c74cee3062452a82d8540adb1b9fe8016734a4e2233defbaf4bf2e1',
      ),
      LocalModelFile(
        path: 'text_decoder.mlmodelc/coremldata.bin',
        sizeBytes: 323,
        sha256:
            'c96efde9c62815e6636dade55c11676d246080776f8ca005c993680752a81d4e',
      ),
      LocalModelFile(
        path: 'text_decoder.mlmodelc/weights/weight.bin',
        sizeBytes: 892593808,
        sha256:
            '7b76d348eeade1d225514012c3b727fce16d2379b92b0fbf1df3e175f852619f',
      ),
      LocalModelFile(
        path: 'vocab.json',
        sizeBytes: 2776833,
        sha256:
            'ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910',
      ),
      LocalModelFile(
        path: 'merges.txt',
        sizeBytes: 1671853,
        sha256:
            '8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5',
      ),
      LocalModelFile(
        path: 'tokenizer_config.json',
        sizeBytes: 12666,
        sha256:
            '3ab80063f8511deb9566e6ad438d17b7a6277fcffd52d92854112f19d36bd81c',
      ),
    ],
  );

  static const forcedAligners = <ForcedAlignmentModel, LocalModelDescriptor>{
    ForcedAlignmentModel.qwen3CoreMlInt8: qwen3ForcedAlignerCoreMlInt8,
    ForcedAlignmentModel.qwen3CoreMlFp16: qwen3ForcedAlignerCoreMlFp16,
  };

  static LocalModelDescriptor forcedAligner(ForcedAlignmentModel model) =>
      forcedAligners[model]!;

  static LocalModelDescriptor? forcedAlignerById(String? modelId) {
    for (final descriptor in forcedAligners.values) {
      if (descriptor.id == modelId) return descriptor;
    }
    return null;
  }

  static const all = [
    mossDiarizeCoreMlInt8,
    qwen3ForcedAlignerCoreMlInt8,
    qwen3ForcedAlignerCoreMlFp16,
  ];
}

enum LocalModelAvailability { missing, partial, ready, corrupt }

class LocalModelStatus {
  const LocalModelStatus({
    required this.descriptor,
    required this.availability,
    required this.downloadedBytes,
  });

  final LocalModelDescriptor descriptor;
  final LocalModelAvailability availability;
  final int downloadedBytes;
}

class LocalModelException implements Exception {
  const LocalModelException(this.code, {this.message});

  final String code;
  final String? message;

  @override
  String toString() => 'LocalModelException($code)';
}

abstract interface class LocalModelManager {
  List<LocalModelDescriptor> get models;
  String pathFor(String modelId);
  Future<LocalModelStatus> status(
    String modelId, {
    bool verifyIntegrity = false,
  });
  Future<void> download(
    String modelId, {
    ModelDownloadProgress? onProgress,
    CancelCheck? shouldCancel,
  });
  Future<void> delete(String modelId);
}

class PreparedLocalPcm {
  const PreparedLocalPcm(this.path);

  final String path;
}

abstract interface class LocalPcmPreparer {
  Future<PreparedLocalPcm> prepare(
    String sourcePath, {
    required int durationMs,
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  });

  Future<void> release(PreparedLocalPcm pcm);
}

enum SpeechWorkerCommand { transcribeMoss, alignQwen3 }

abstract interface class LocalSpeechWorker {
  Future<Map<String, dynamic>> run(
    SpeechWorkerCommand command,
    Map<String, dynamic> request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  });
}

class LocalSttRequest {
  const LocalSttRequest({
    required this.sourcePath,
    required this.durationMs,
    required this.options,
  });

  final String sourcePath;
  final int durationMs;
  final TranscriptionOptions options;
}

abstract interface class LocalSttService {
  bool get isSupported;

  Future<TranscriptDocument> transcribe(
    LocalSttRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  });
}

class ForcedAlignmentRequest {
  const ForcedAlignmentRequest({
    required this.sourcePath,
    required this.document,
    required this.model,
    this.languageHints = const [],
  });

  final String sourcePath;
  final TranscriptDocument document;
  final LocalModelDescriptor model;
  final List<String> languageHints;
}

class AlignmentResult {
  const AlignmentResult({
    required this.tokens,
    required this.status,
    required this.alignedSegments,
    required this.totalSegments,
    this.languageAutomaticallyDetermined = false,
    this.warningCode,
    this.warningMessage,
  });

  final List<TranscriptToken> tokens;
  final ForcedAlignmentStatus status;
  final int alignedSegments;
  final int totalSegments;
  final bool languageAutomaticallyDetermined;
  final String? warningCode;
  final String? warningMessage;

  ForcedAlignmentState toState(LocalModelDescriptor model) =>
      ForcedAlignmentState(
        status: status,
        modelId: model.id,
        modelRevision: model.revision,
        alignedSegments: alignedSegments,
        totalSegments: totalSegments,
        languageAutomaticallyDetermined: languageAutomaticallyDetermined,
        warningCode: warningCode,
        warningMessage: warningMessage,
      );
}

abstract interface class ForcedAlignmentService {
  bool get isSupported;

  Future<AlignmentResult> align(
    ForcedAlignmentRequest request, {
    ProgressCallback? onProgress,
    CancelCheck? shouldCancel,
  });
}

class LocalSpeechException implements Exception {
  const LocalSpeechException(this.code, {this.message});

  final String code;
  final String? message;

  @override
  String toString() => 'LocalSpeechException($code)';
}
