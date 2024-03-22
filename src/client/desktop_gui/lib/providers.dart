import 'dart:async';
import 'dart:io';

import 'package:basics/basics.dart';
import 'package:built_collection/built_collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fpdart/fpdart.dart';
import 'package:grpc/grpc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ffi.dart';
import 'grpc_client.dart';
import 'logger.dart';

export 'grpc_client.dart';

final grpcClientProvider = Provider((_) {
  final address = getServerAddress();
  final certPair = getCertPair();

  var channelCredentials = CustomChannelCredentials(
    authority: 'localhost',
    certificate: certPair.cert,
    certificateKey: certPair.key,
  );

  return GrpcClient(RpcClient(ClientChannel(
    address.scheme == InternetAddressType.unix.name.toLowerCase()
        ? InternetAddress(address.path, type: InternetAddressType.unix)
        : address.host,
    port: address.port,
    options: ChannelOptions(credentials: channelCredentials),
    channelShutdownHandler: () => logger.w('gRPC channel shut down'),
  )));
});

final vmInfosStreamProvider = StreamProvider<List<VmInfo>>((ref) async* {
  final grpcClient = ref.watch(grpcClientProvider);
  // this is to de-duplicate errors received from the stream
  Object? lastError;
  while (true) {
    final timer = Future.delayed(900.milliseconds);
    try {
      yield await grpcClient.info();
      lastError = null;
    } catch (error, stackTrace) {
      if (error != lastError) {
        logger.e('Error on polling info', error: error, stackTrace: stackTrace);
        yield* Stream.error(error, stackTrace);
      }
      lastError = error;
    }
    await timer;
    // this is so that if the request takes less than 900 milliseconds, it waits the rest of the 900 that remain plus 100 milliseconds
    // this is so that there is 1 second pause between requests that take less than 1 second
    // but if the timer is done before the request completes, it still waits at least 100 milliseconds before the next request
    // so that it does not spam the daemon if requests take longer to complete
    await Future.delayed(100.milliseconds);
  }
});

final daemonAvailableProvider = Provider((ref) {
  return !ref.watch(vmInfosStreamProvider).hasError;
});

final vmInfosProvider = Provider((ref) {
  return ref.watch(vmInfosStreamProvider).valueOrNull ?? const [];
});

final vmInfosMapProvider = Provider((ref) {
  return {for (final info in ref.watch(vmInfosProvider)) info.name: info};
});

class VmInfoNotifier
    extends AutoDisposeFamilyNotifier<DetailedInfoItem, String> {
  @override
  DetailedInfoItem build(String arg) {
    return ref.watch(vmInfosMapProvider)[arg] ?? DetailedInfoItem();
  }
}

final vmInfoProvider = NotifierProvider.autoDispose
    .family<VmInfoNotifier, DetailedInfoItem, String>(VmInfoNotifier.new);

final vmStatusesProvider = Provider((ref) {
  return ref
      .watch(vmInfosMapProvider)
      .mapValue((info) => info.instanceStatus.status)
      .build();
});

final vmNamesProvider = Provider((ref) {
  return ref.watch(vmStatusesProvider).keys.toBuiltSet();
});

class ClientSettingNotifier extends AutoDisposeFamilyNotifier<String, String> {
  final file = File(settingsFile());

  @override
  String build(String arg) {
    file.parent
        .watch(events: FileSystemEvent.modify)
        .where((event) => event.path == file.path)
        .first
        .whenComplete(() => Timer(50.milliseconds, ref.invalidateSelf));
    return getSetting(arg);
  }

  void set(String value) => setSetting(arg, value);

  @override
  bool updateShouldNotify(String previous, String next) => previous != next;
}

const primaryNameKey = 'client.primary-name';
final clientSettingProvider = NotifierProvider.autoDispose
    .family<ClientSettingNotifier, String, String>(ClientSettingNotifier.new);

class DaemonSettingNotifier
    extends AutoDisposeFamilyAsyncNotifier<String, String> {
  @override
  Future<String> build(String arg) async {
    return ref.watch(daemonAvailableProvider)
        ? await ref.watch(grpcClientProvider).get(arg)
        : state.valueOrNull ?? await Completer<String>().future;
  }

  void set(String value) {
    ref
        .read(grpcClientProvider)
        .set(arg, value)
        .whenComplete(() => Timer(50.milliseconds, ref.invalidateSelf))
        .ignore();
  }

  @override
  bool updateShouldNotify(
    AsyncValue<String> previous,
    AsyncValue<String> next,
  ) {
    return previous != next;
  }
}

const driverKey = 'local.driver';
const bridgedNetworkKey = 'local.bridged-network';
const privilegedMountsKey = 'local.privileged-mounts';
const passphraseKey = 'local.passphrase';
final daemonSettingProvider = AsyncNotifierProvider.autoDispose
    .family<DaemonSettingNotifier, String, String>(DaemonSettingNotifier.new);

class GuiSettingNotifier extends AutoDisposeFamilyNotifier<String?, String> {
  final SharedPreferences sharedPreferences;

  GuiSettingNotifier(this.sharedPreferences);

  @override
  String? build(String arg) {
    return sharedPreferences.getString(arg);
  }

  void set(String value) {
    sharedPreferences.setString(arg, value);
    state = value;
  }

  @override
  bool updateShouldNotify(String? previous, String? next) => previous != next;
}

const onAppCloseKey = 'onAppClose';
const hotkeyKey = 'hotkey';
// this provider is set with a value obtained asynchronously in main.dart
final guiSettingProvider = NotifierProvider.autoDispose
    .family<GuiSettingNotifier, String?, String>(() {
  throw UnimplementedError();
});

final networksProvider = Provider.autoDispose((ref) {
  final driver = ref.watch(daemonSettingProvider(driverKey)).valueOrNull;
  if (driver != null && ref.watch(daemonAvailableProvider)) {
    ref.watch(grpcClientProvider).networks().then((networks) {
      ref.state = networks.map((n) => n.name).toBuiltSet();
    }).ignore();
  }
  return BuiltSet<String>();
});
