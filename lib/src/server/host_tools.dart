import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protocol.dart';
import 'paths.dart';

typedef Log = void Function(String message);

/// What the hub does on the computer itself: the clipboard, desktop
/// notifications, `adb reverse` for Android devices, the LAN address.
class HostTools {
  HostTools({Log? log}) : _log = log ?? ((_) {});

  final Log _log;

  /// Copies [text] to the clipboard. Returns whether it worked.
  Future<bool> copyToClipboard(String text) async {
    final candidates = <List<String>>[
      if (Platform.isMacOS) ['pbcopy'],
      if (Platform.isWindows)
        ['powershell', '-NoProfile', '-Command', r'[Console]::InputEncoding=[Text.Encoding]::UTF8; Set-Clipboard -Value ([Console]::In.ReadToEnd())'],
      if (Platform.isLinux) ...[
        ['wl-copy'],
        ['xclip', '-selection', 'clipboard'],
        ['xsel', '--clipboard', '--input'],
      ],
    ];
    for (final command in candidates) {
      try {
        final process = await Process.start(command.first, command.sublist(1));
        process.stdin.add(utf8.encode(text));
        await process.stdin.close();
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
        final code = await process.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
          process.kill();
          return -1;
        });
        if (code == 0) return true;
      } catch (_) {
        // Not installed; try the next one.
      }
    }
    _log('clipboard: no clipboard tool worked');
    return false;
  }

  /// Shows a desktop notification. Best effort.
  Future<void> notify(String title, String body) async {
    try {
      if (Platform.isMacOS) {
        final script = 'display notification ${_appleString(body)} with title ${_appleString(title)}';
        await Process.run('osascript', ['-e', script]).timeout(const Duration(seconds: 5));
      } else if (Platform.isLinux) {
        await Process.run('notify-send', ['--app-name=fixkit', title, body]).timeout(const Duration(seconds: 5));
      } else if (Platform.isWindows) {
        final script = [
          'Add-Type -AssemblyName System.Windows.Forms',
          r'$n = New-Object System.Windows.Forms.NotifyIcon',
          r'$n.Icon = [System.Drawing.SystemIcons]::Information',
          r'$n.Visible = $true',
          '\$n.ShowBalloonTip(6000, ${_psString(title)}, ${_psString(body)}, "Info")',
          'Start-Sleep -Seconds 7',
          r'$n.Dispose()',
        ].join('; ');
        await Process.start('powershell', ['-NoProfile', '-Command', script], mode: ProcessStartMode.detached);
      }
    } catch (error) {
      _log('notify: $error');
    }
  }

  String _appleString(String text) => '"${text.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

  String _psString(String text) => "'${text.replaceAll("'", "''")}'";

  // ---- adb reverse -------------------------------------------------------

  String? _adb;
  DateTime? _adbSearchedAt;
  final Set<String> _reversed = {};

  /// Where adb is: on PATH, or in the Android SDK's usual places.
  String? findAdb() {
    // Not found is looked up again after a minute: the SDK may arrive later.
    final searched = _adbSearchedAt;
    if (_adb != null || (searched != null && DateTime.now().difference(searched) < const Duration(minutes: 1))) return _adb;
    _adbSearchedAt = DateTime.now();
    final exe = Platform.isWindows ? 'adb.exe' : 'adb';
    final env = Platform.environment;
    final home = homeDirectory();
    // The Android SDK's own adb first, the one `flutter run` uses: a
    // different adb version (an older one on PATH, say) restarts the adb
    // server on every call, which drops the reverse and disturbs flutter.
    final dirs = <String>[
      // The SDK `flutter config --android-sdk` points at.
      for (final sdk in _flutterAndroidSdks(home, env)) joinPath(sdk, 'platform-tools'),
      for (final key in ['ANDROID_HOME', 'ANDROID_SDK_ROOT'])
        if (env[key] != null) joinPath(env[key]!, 'platform-tools'),
      if (Platform.isMacOS) joinPath(home, 'Library', 'Android', 'sdk', 'platform-tools'),
      if (Platform.isLinux) joinPath(home, 'Android', 'Sdk', 'platform-tools'),
      if (Platform.isWindows && env['LOCALAPPDATA'] != null)
        joinPath(env['LOCALAPPDATA']!, 'Android', 'Sdk', 'platform-tools'),
      ...?env['PATH']?.split(Platform.isWindows ? ';' : ':'),
    ];
    for (final dir in dirs) {
      if (dir.isEmpty) continue;
      final candidate = joinPath(dir, exe);
      if (File(candidate).existsSync()) return _adb = candidate;
    }
    return null;
  }

  Iterable<String> _flutterAndroidSdks(String home, Map<String, String> env) sync* {
    final files = [
      joinPath(home, '.flutter_settings'),
      joinPath(home, '.config', 'flutter', 'settings'),
      if (env['APPDATA'] != null) joinPath(env['APPDATA']!, '.flutter_settings'),
      if (env['APPDATA'] != null) joinPath(env['APPDATA']!, 'flutter', 'settings'),
    ];
    for (final path in files) {
      try {
        final json = jsonDecode(File(path).readAsStringSync());
        if (json is Map && json['android-sdk'] is String) yield json['android-sdk'] as String;
      } catch (_) {
        // Not there.
      }
    }
  }

  /// Every device adb lists, with its state: `device` (ready),
  /// `unauthorized` (the phone has not allowed USB debugging), `offline`...
  Future<Map<String, String>> adbDeviceStates() async {
    final adb = findAdb();
    if (adb == null) return const {};
    try {
      final result = await Process.run(adb, ['devices']).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return const {};
      return {
        for (final line in LineSplitter.split('${result.stdout}').skip(1))
          if (line.trim().split(RegExp(r'\s+')).length >= 2)
            line.trim().split(RegExp(r'\s+'))[0]: line.trim().split(RegExp(r'\s+'))[1],
      };
    } catch (_) {
      return const {};
    }
  }

  /// Makes 127.0.0.1:[port] on the device [serial] reach this computer, if it
  /// does not already. True when it does.
  Future<bool> ensureReverse(String serial, {int port = fixkitPort}) async {
    final adb = findAdb();
    if (adb == null) return false;
    if (await _stillReversed(adb, serial, port)) return true;
    try {
      final result = await Process.run(adb, ['-s', serial, 'reverse', 'tcp:$port', 'tcp:$port'])
          .timeout(const Duration(seconds: 5));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Serial numbers of the Android devices and emulators adb sees.
  Future<List<String>> adbDevices() async {
    final adb = findAdb();
    if (adb == null) return const [];
    try {
      final result = await Process.run(adb, ['devices']).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return const [];
      return [
        for (final line in LineSplitter.split('${result.stdout}').skip(1))
          if (line.trim().endsWith('\tdevice') || RegExp(r'\sdevice$').hasMatch(line.trim()))
            line.trim().split(RegExp(r'\s+')).first,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Makes 127.0.0.1:[port] on every connected Android device reach this
  /// computer. Runs again for devices that reconnect.
  Future<void> reverseAndroidPorts({int port = fixkitPort}) async {
    final adb = findAdb();
    if (adb == null) return;
    final devices = await adbDevices();
    _reversed.removeWhere((serial) => !devices.contains(serial));
    for (final serial in devices) {
      // `flutter run` and IDEs restart the adb server now and then, which
      // drops every reverse: check it is still there, not just that it was set.
      if (_reversed.contains(serial) && await _stillReversed(adb, serial, port)) continue;
      _reversed.remove(serial);
      try {
        final result = await Process.run(adb, ['-s', serial, 'reverse', 'tcp:$port', 'tcp:$port'])
            .timeout(const Duration(seconds: 5));
        if (result.exitCode == 0) {
          _reversed.add(serial);
          _log('adb reverse tcp:$port on $serial');
        } else {
          _log('adb reverse failed on $serial: ${result.stderr}');
        }
      } catch (error) {
        _log('adb reverse failed on $serial: $error');
      }
    }
  }

  Future<bool> _stillReversed(String adb, String serial, int port) async {
    try {
      final result = await Process.run(adb, ['-s', serial, 'reverse', '--list']).timeout(const Duration(seconds: 5));
      return result.exitCode == 0 && '${result.stdout}'.contains('tcp:$port');
    } catch (_) {
      return false;
    }
  }

  Set<String> get reversedDevices => Set.unmodifiable(_reversed);

  /// The port on this computer that `adb forward` (set up by `flutter run`)
  /// sends to [devicePort] on an Android device, if any.
  Future<int?> adbForwardedPort(int devicePort) async {
    final adb = findAdb();
    if (adb == null) return null;
    try {
      final result = await Process.run(adb, ['forward', '--list']).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return null;
      for (final line in LineSplitter.split('${result.stdout}')) {
        final match = RegExp(r'tcp:(\d+)\s+tcp:(\d+)\s*$').firstMatch(line.trim());
        if (match != null && int.parse(match[2]!) == devicePort) return int.parse(match[1]!);
      }
    } catch (_) {}
    return null;
  }

  /// The computer's address on the local network, for phones on Wi-Fi.
  Future<String?> lanAddress() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
      String? fallback;
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final ip = address.address;
          final private = ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
          if (!private) continue;
          final name = interface.name.toLowerCase();
          // Wi-Fi and Ethernet first; virtual adapters (Docker, VPNs) last.
          final virtual = name.contains('docker') || name.contains('vbox') || name.contains('vmnet') ||
              name.startsWith('br-') || name.startsWith('utun') || name.contains('veth');
          if (!virtual) return ip;
          fallback ??= ip;
        }
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }
}
