import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/contracts.dart';
import '../core/local_speech.dart';

typedef LocalModelDigest = Future<String> Function(File file);

class HttpLocalModelManager implements LocalModelManager {
  HttpLocalModelManager({
    required Directory modelsDirectory,
    http.Client? client,
    List<LocalModelDescriptor> descriptors = LocalSpeechModels.all,
    LocalModelDigest? digestFile,
  }) : _modelsDirectory = modelsDirectory,
       _client = client ?? http.Client(),
       _digestFile = digestFile ?? _sha256File,
       _descriptors = {
         for (final descriptor in descriptors) descriptor.id: descriptor,
       };

  static const legacyGGUFModelIds = {
    'moss-transcribe-diarize-0.9b-q8_0',
    'qwen3-forced-aligner-0.6b-q8_0',
  };
  static const legacyGGUFFileNames = {
    'moss-transcribe-diarize-0.9b-q8_0.gguf',
    'qwen3-forced-aligner-0.6b-q8_0.gguf',
  };

  final Directory _modelsDirectory;
  final http.Client _client;
  final LocalModelDigest _digestFile;
  final Map<String, LocalModelDescriptor> _descriptors;
  final Map<String, Future<LocalModelStatus>> _verifications = {};

  @override
  List<LocalModelDescriptor> get models =>
      List.unmodifiable(_descriptors.values);

  LocalModelDescriptor _descriptor(String modelId) {
    final descriptor = _descriptors[modelId];
    if (descriptor == null) {
      throw LocalModelException('model_unknown', message: modelId);
    }
    return descriptor;
  }

  @override
  String pathFor(String modelId) =>
      p.join(_modelsDirectory.path, _descriptor(modelId).id);

  Directory _installed(LocalModelDescriptor descriptor) =>
      Directory(pathFor(descriptor.id));

  Directory _staging(LocalModelDescriptor descriptor) =>
      Directory(p.join(_modelsDirectory.path, '.${descriptor.id}.part'));

  File _bundleFile(Directory root, LocalModelFile file) =>
      File(p.join(root.path, file.path));

  File _partialFile(Directory root, LocalModelFile file) =>
      File('${_bundleFile(root, file).path}.part');

  File _verificationReceipt(Directory root) =>
      File(p.join(root.path, '.verified.json'));

  @override
  Future<LocalModelStatus> status(
    String modelId, {
    bool verifyIntegrity = false,
  }) async {
    final descriptor = _descriptor(modelId);
    final installed = _installed(descriptor);
    if (await installed.exists()) {
      final sizes = await _bundleSizes(installed, descriptor);
      if (!sizes.complete) {
        return LocalModelStatus(
          descriptor: descriptor,
          availability: LocalModelAvailability.corrupt,
          downloadedBytes: sizes.bytes,
        );
      }
      if (!verifyIntegrity || await _receiptMatches(installed, descriptor)) {
        return LocalModelStatus(
          descriptor: descriptor,
          availability: LocalModelAvailability.ready,
          downloadedBytes: descriptor.sizeBytes,
        );
      }
      return _verifyInstalled(descriptor, installed);
    }

    final staged = _staging(descriptor);
    if (!await staged.exists()) {
      return LocalModelStatus(
        descriptor: descriptor,
        availability: LocalModelAvailability.missing,
        downloadedBytes: 0,
      );
    }
    final stagedStatus = await _stagedBytes(
      staged,
      descriptor,
      verifyIntegrity: verifyIntegrity,
    );
    var corrupt = stagedStatus.corrupt;
    if (verifyIntegrity && stagedStatus.complete) {
      corrupt = !await _allFilesMatch(staged, descriptor);
    }
    return LocalModelStatus(
      descriptor: descriptor,
      availability: corrupt
          ? LocalModelAvailability.corrupt
          : LocalModelAvailability.partial,
      downloadedBytes: stagedStatus.bytes,
    );
  }

  @override
  Future<void> download(
    String modelId, {
    ModelDownloadProgress? onProgress,
    CancelCheck? shouldCancel,
  }) async {
    final descriptor = _descriptor(modelId);
    final current = await status(modelId, verifyIntegrity: true);
    if (current.availability == LocalModelAvailability.ready) {
      onProgress?.call(descriptor.sizeBytes, descriptor.sizeBytes);
      return;
    }
    _throwIfCancelled(shouldCancel);

    final installed = _installed(descriptor);
    final staging = _staging(descriptor);
    await _modelsDirectory.create(recursive: true);
    if (await installed.exists()) await installed.delete(recursive: true);
    await staging.create(recursive: true);

    var completedBytes = 0;
    for (final file in descriptor.files) {
      _throwIfCancelled(shouldCancel);
      final target = _bundleFile(staging, file);
      final partial = _partialFile(staging, file);
      await target.parent.create(recursive: true);

      if (await target.exists()) {
        if (await target.length() == file.sizeBytes &&
            await _digestFile(target) == file.sha256) {
          completedBytes += file.sizeBytes;
          onProgress?.call(completedBytes, descriptor.sizeBytes);
          continue;
        }
        await target.delete();
      }

      if (await partial.exists() && await partial.length() == file.sizeBytes) {
        if (await _digestFile(partial) == file.sha256) {
          await partial.rename(target.path);
          completedBytes += file.sizeBytes;
          onProgress?.call(completedBytes, descriptor.sizeBytes);
          continue;
        }
        await partial.delete();
      }
      var offset = await partial.exists() ? await partial.length() : 0;
      if (offset > file.sizeBytes) {
        await partial.delete();
        offset = 0;
      }

      final request = http.Request('GET', descriptor.downloadUriFor(file));
      if (offset > 0) request.headers['Range'] = 'bytes=$offset-';
      final response = await _client
          .send(request)
          .timeout(const Duration(minutes: 2));
      final resumes =
          offset > 0 && response.statusCode == HttpStatus.partialContent;
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        throw LocalModelException(
          'model_download_failed',
          message: 'HTTP ${response.statusCode}',
        );
      }
      if (!resumes) offset = 0;

      final sink = partial.openWrite(
        mode: resumes ? FileMode.append : FileMode.write,
      );
      var downloaded = offset;
      try {
        await for (final chunk in response.stream) {
          _throwIfCancelled(shouldCancel);
          sink.add(chunk);
          downloaded += chunk.length;
          onProgress?.call(completedBytes + downloaded, descriptor.sizeBytes);
        }
      } finally {
        await sink.close();
      }

      if (downloaded != file.sizeBytes) {
        throw LocalModelException(
          'model_size_mismatch',
          message: '${file.path}: $downloaded/${file.sizeBytes}',
        );
      }
      if (await _digestFile(partial) != file.sha256) {
        throw LocalModelException(
          'model_checksum_mismatch',
          message: file.path,
        );
      }
      await partial.rename(target.path);
      completedBytes += file.sizeBytes;
      onProgress?.call(completedBytes, descriptor.sizeBytes);
    }

    await _writeVerificationReceipt(staging, descriptor);
    if (await installed.exists()) await installed.delete(recursive: true);
    await staging.rename(installed.path);
    onProgress?.call(descriptor.sizeBytes, descriptor.sizeBytes);
  }

  @override
  Future<void> delete(String modelId) async {
    final descriptor = _descriptor(modelId);
    for (final directory in [_installed(descriptor), _staging(descriptor)]) {
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }

  Future<void> removeLegacyGGUFModels() async {
    for (final fileName in legacyGGUFFileNames) {
      for (final name in [fileName, '$fileName.part']) {
        final file = File(p.join(_modelsDirectory.path, name));
        if (await file.exists()) await file.delete();
      }
    }
    for (final id in legacyGGUFModelIds) {
      for (final name in [id, '.$id.part']) {
        final directory = Directory(p.join(_modelsDirectory.path, name));
        if (await directory.exists()) await directory.delete(recursive: true);
      }
    }
  }

  Future<LocalModelStatus> _verifyInstalled(
    LocalModelDescriptor descriptor,
    Directory installed,
  ) {
    final active = _verifications[descriptor.id];
    if (active != null) return active;
    final operation = _performInstalledVerification(descriptor, installed);
    _verifications[descriptor.id] = operation;
    return operation.whenComplete(() {
      if (identical(_verifications[descriptor.id], operation)) {
        _verifications.remove(descriptor.id);
      }
    });
  }

  Future<LocalModelStatus> _performInstalledVerification(
    LocalModelDescriptor descriptor,
    Directory installed,
  ) async {
    final valid = await _allFilesMatch(installed, descriptor);
    if (valid) {
      await _writeVerificationReceipt(installed, descriptor);
    } else {
      await _deleteVerificationReceipt(installed);
    }
    final sizes = await _bundleSizes(installed, descriptor);
    return LocalModelStatus(
      descriptor: descriptor,
      availability: valid
          ? LocalModelAvailability.ready
          : LocalModelAvailability.corrupt,
      downloadedBytes: sizes.bytes,
    );
  }

  Future<bool> _allFilesMatch(
    Directory root,
    LocalModelDescriptor descriptor,
  ) async {
    for (final expected in descriptor.files) {
      final file = _bundleFile(root, expected);
      if (!await file.exists() || await file.length() != expected.sizeBytes) {
        return false;
      }
      if (await _digestFile(file) != expected.sha256) return false;
    }
    return true;
  }

  Future<bool> _receiptMatches(
    Directory root,
    LocalModelDescriptor descriptor,
  ) async {
    final receipt = _verificationReceipt(root);
    if (!await receipt.exists()) return false;
    try {
      final value = jsonDecode(await receipt.readAsString());
      if (value is! Map ||
          value['version'] != 2 ||
          value['revision'] != descriptor.revision ||
          value['files'] is! Map) {
        return false;
      }
      final files = value['files'] as Map;
      for (final expected in descriptor.files) {
        final recorded = files[expected.path];
        if (recorded is! Map) return false;
        final file = _bundleFile(root, expected);
        if (!await file.exists()) return false;
        final stat = await file.stat();
        if (recorded['size_bytes'] != stat.size ||
            recorded['modified_us'] !=
                stat.modified.toUtc().microsecondsSinceEpoch ||
            recorded['sha256'] != expected.sha256) {
          return false;
        }
      }
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _writeVerificationReceipt(
    Directory root,
    LocalModelDescriptor descriptor,
  ) async {
    final files = <String, Object>{};
    for (final expected in descriptor.files) {
      final stat = await _bundleFile(root, expected).stat();
      files[expected.path] = {
        'size_bytes': stat.size,
        'modified_us': stat.modified.toUtc().microsecondsSinceEpoch,
        'sha256': expected.sha256,
      };
    }
    final receipt = _verificationReceipt(root);
    final partial = File('${receipt.path}.part');
    await partial.writeAsString(
      jsonEncode({
        'version': 2,
        'revision': descriptor.revision,
        'files': files,
      }),
      flush: true,
    );
    if (await receipt.exists()) await receipt.delete();
    await partial.rename(receipt.path);
  }

  Future<void> _deleteVerificationReceipt(Directory root) async {
    final receipt = _verificationReceipt(root);
    if (await receipt.exists()) await receipt.delete();
  }

  Future<_BundleSizes> _bundleSizes(
    Directory root,
    LocalModelDescriptor descriptor,
  ) async {
    var bytes = 0;
    var complete = true;
    for (final expected in descriptor.files) {
      final file = _bundleFile(root, expected);
      if (!await file.exists()) {
        complete = false;
        continue;
      }
      final length = await file.length();
      bytes += length;
      if (length != expected.sizeBytes) complete = false;
    }
    return _BundleSizes(bytes: bytes, complete: complete);
  }

  Future<_StagedStatus> _stagedBytes(
    Directory root,
    LocalModelDescriptor descriptor, {
    bool verifyIntegrity = false,
  }) async {
    var bytes = 0;
    var corrupt = false;
    var complete = true;
    for (final expected in descriptor.files) {
      final target = _bundleFile(root, expected);
      final partial = _partialFile(root, expected);
      if (await target.exists()) {
        final length = await target.length();
        bytes += length;
        if (length != expected.sizeBytes) corrupt = true;
        if (verifyIntegrity &&
            length == expected.sizeBytes &&
            await _digestFile(target) != expected.sha256) {
          corrupt = true;
        }
        continue;
      }
      complete = false;
      if (await partial.exists()) {
        final length = await partial.length();
        bytes += length;
        if (length > expected.sizeBytes) corrupt = true;
        if (verifyIntegrity &&
            length == expected.sizeBytes &&
            await _digestFile(partial) != expected.sha256) {
          corrupt = true;
        }
      }
    }
    return _StagedStatus(bytes: bytes, corrupt: corrupt, complete: complete);
  }

  void _throwIfCancelled(CancelCheck? shouldCancel) {
    if (shouldCancel?.call() ?? false) {
      throw const OperationCancelledException();
    }
  }
}

class _BundleSizes {
  const _BundleSizes({required this.bytes, required this.complete});

  final int bytes;
  final bool complete;
}

class _StagedStatus {
  const _StagedStatus({
    required this.bytes,
    required this.corrupt,
    required this.complete,
  });

  final int bytes;
  final bool corrupt;
  final bool complete;
}

Future<String> _sha256File(File file) =>
    Isolate.run(() => _sha256Path(file.path));

Future<String> _sha256Path(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();
