import 'transport.dart';

/// Web: keine Handy-Fernbedienung (kein `dart:io`).
Future<RemoteServerHandle> startRemoteServer(RemoteTvHost host,
        {Object? bindAddress,
        Object? pairGate,
        Object? authGate,
        int preferredPort = 0,
        Duration pairTimeout = const Duration(minutes: 3)}) =>
    throw UnsupportedError('remote');

Future<RemoteConnection> connectRemote(String host, int port,
        {Duration timeout = const Duration(seconds: 5),
        bool allowLoopback = false}) =>
    throw UnsupportedError('remote');
