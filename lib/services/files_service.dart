import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:photos/core/configuration.dart';
import 'package:photos/core/network/network.dart';
import 'package:photos/db/files_db.dart';
import 'package:photos/extensions/list.dart';
import 'package:photos/models/file/file.dart';
import "package:photos/models/file_load_result.dart";
import "package:photos/models/metadata/file_magic.dart";
import 'package:photos/services/file_magic_service.dart';
import "package:photos/services/ignored_files_service.dart";
import 'package:photos/utils/date_time_util.dart';

class FilesService {
  late Dio _enteDio;
  late Logger _logger;
  late FilesDB _filesDB;
  late Configuration _config;

  FilesService._privateConstructor() {
    _enteDio = NetworkClient.instance.enteDio;
    _logger = Logger("FilesService");
    _filesDB = FilesDB.instance;
    _config = Configuration.instance;
  }

  static final FilesService instance = FilesService._privateConstructor();

  Future<int> getFileSize(int uploadedFileID) async {
    try {
      final response = await _enteDio.post(
        "/files/size",
        data: {
          "fileIDs": [uploadedFileID],
        },
      );
      return response.data["size"];
    } catch (e) {
      _logger.severe(e);
      rethrow;
    }
  }

  Future<bool> hasMigratedSizes() async {
    try {
      final List<int> uploadIDsWithMissingSize =
          await _filesDB.getUploadIDsWithMissingSize(_config.getUserID()!);
      if (uploadIDsWithMissingSize.isEmpty) {
        return Future.value(true);
      }
      final batchedFiles = uploadIDsWithMissingSize.chunks(1000);
      for (final batch in batchedFiles) {
        final Map<int, int> uploadIdToSize = await getFilesSizeFromInfo(batch);
        await _filesDB.updateSizeForUploadIDs(uploadIdToSize);
      }
      return Future.value(true);
    } catch (e, s) {
      _logger.severe("error during has migrated sizes", e, s);
      return Future.value(false);
    }
  }

  Future<Map<int, int>> getFilesSizeFromInfo(List<int> uploadedFileID) async {
    try {
      final response = await _enteDio.post(
        "/files/info",
        data: {"fileIDs": uploadedFileID},
      );
      final Map<int, int> idToSize = {};
      final List result = response.data["filesInfo"] as List;
      for (var fileInfo in result) {
        final int uploadedFileID = fileInfo["id"];
        final int size = fileInfo["fileInfo"]["fileSize"];
        idToSize[uploadedFileID] = size;
      }
      return idToSize;
    } catch (e, s) {
      _logger.severe("failed to fetch size from fileInfo", e, s);
      rethrow;
    }
  }

  // Note: this method is not used anywhere, but it is kept for future
  // reference when we add bulk EditTime feature
  Future<void> bulkEditTime(
    List<EnteFile> files,
    EditTimeSource source,
  ) async {
    final ListMatch<EnteFile> result = files.splitMatch(
      (element) => element.isUploaded,
    );
    final List<EnteFile> uploadedFiles = result.matched;
    // editTime For LocalFiles
    final List<EnteFile> localOnlyFiles = result.unmatched;
    for (EnteFile localFile in localOnlyFiles) {
      final timeResult = _parseTime(localFile, source);
      if (timeResult != null) {
        localFile.creationTime = timeResult;
      }
    }
    await _filesDB.insertMultiple(localOnlyFiles);

    final List<EnteFile> remoteFilesToUpdate = [];
    final Map<int, Map<String, int>> fileIDToUpdateMetadata = {};
    for (EnteFile remoteFile in uploadedFiles) {
      // discard files not owned by user and also dedupe already processed
      // files
      if (remoteFile.ownerID != _config.getUserID()! ||
          fileIDToUpdateMetadata.containsKey(remoteFile.uploadedFileID!)) {
        continue;
      }
      final timeResult = _parseTime(remoteFile, source);
      if (timeResult != null) {
        remoteFilesToUpdate.add(remoteFile);
        fileIDToUpdateMetadata[remoteFile.uploadedFileID!] = {
          editTimeKey: timeResult,
        };
      }
    }
    if (remoteFilesToUpdate.isNotEmpty) {
      await FileMagicService.instance.updatePublicMagicMetadata(
        remoteFilesToUpdate,
        null,
        metadataUpdateMap: fileIDToUpdateMetadata,
      );
    }
  }

  int? _parseTime(EnteFile file, EditTimeSource source) {
    assert(
      source == EditTimeSource.fileName,
      "edit source ${source.name} is not supported yet",
    );
    final timeResult = parseDateTimeFromFileNameV2(
      basenameWithoutExtension(file.title ?? ""),
    );
    return timeResult?.microsecondsSinceEpoch;
  }

  Future<void> removeIgnoredFiles(Future<FileLoadResult> result) async {
    final ignoredIDs = await IgnoredFilesService.instance.idToIgnoreReasonMap;
    (await result).files.removeWhere(
          (f) =>
              f.uploadedFileID == null &&
              IgnoredFilesService.instance.shouldSkipUpload(ignoredIDs, f),
        );
  }
}

enum EditTimeSource {
  // parse the time from fileName
  fileName,
  // parse the time from exif data of file.
  exif,
  // use the which user provided as input
  manualFix,
  // adjust the time of selected photos by +/- time.
  // required for cases when the original device in which photos were taken
  // had incorrect time (quite common with physical cameras)
  manualAdjusted,
}
