import 'network_recorder.dart';

/// The running client's recorder; null before init and after shutdown.
/// Interceptors read it on every request, so one created before init (or
/// kept across a re-init) starts measuring as soon as the SDK runs.
NetworkRecorder? activeNetworkRecorder;
