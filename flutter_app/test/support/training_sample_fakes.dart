import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:relationship_manager/services/recording_file_store.dart';

class CaptureTrainingHttp extends http.BaseClient {
  http.MultipartRequest? request;
  List<int>? body;
  int calls = 0;
  int status = 201;
  String? responseBody;
  Object? failure;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    this.request = request as http.MultipartRequest;
    body = await request.finalize().toBytes();
    if (failure != null) throw failure!;
    final id =
        (jsonDecode(this.request!.fields['metadata']!) as Map)['sampleId'];
    return http.StreamedResponse(
        Stream.value(utf8.encode(
            responseBody ?? jsonEncode({'id': id, 'date': '2026-10-04'}))),
        status);
  }
}

class ReportRecordingStore extends RecordingFileStore {
  bool present = true;
  int sizeBytes = 48;
  int streamReads = 0;
  int sizeReads = 0;
  List<List<int>> chunks = [List.generate(48, (i) => i)];

  @override
  Future<bool> exists(String id) async => present;
  @override
  Future<int> size(String id) async {
    sizeReads++;
    return sizeBytes;
  }

  @override
  Stream<List<int>> openReadStream(String id) {
    streamReads++;
    return Stream.fromIterable(chunks);
  }

  @override
  Future<Uint8List> readBytes(String id) =>
      throw StateError('Must stream audio');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
