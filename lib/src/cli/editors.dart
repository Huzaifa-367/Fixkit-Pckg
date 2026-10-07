import 'dart:io';

import '../server/paths.dart';
import 'jsonc.dart';
import 'project.dart';

/// An editor or agent whose MCP config fixkit writes.
class EditorTarget {
  const EditorTarget({
    required this.id,
    required this.name,
    required this.configPath,
    required this.serversKey,
    this.global = false,
    this.vscodeFormat = false,
    this.trust = false,
  });

  /// `cursor`, `vscode`, `antigravity`, `windsurf`, `claude`, `gemini`.
  final String id;
  final String name;

  /// The MCP config file.
  final String configPath;

  /// The key the servers sit under: `mcpServers`, or `servers` for VS Code.
  final String serversKey;

  /// A computer-wide config shared by every project: fixkit's entry there
  /// takes reports from whatever project the editor has open.
  final bool global;

  /// VS Code's format (`"type": "stdio"`).
  final bool vscodeFormat;

  /// Mark the server as trusted, so its tools run without asking (Gemini CLI).
  final bool trust;

  File get file => File(configPath);
}

const List<String> allEditorIds = ['cursor', 'vscode', 'antigravity', 'windsurf', 'claude', 'gemini'];

/// The editors on this computer, or [only] those named.
List<EditorTarget> detectEditors(Project project, {Set<String>? only}) {
  final home = homeDirectory();
  bool dir(String path) => Directory(path).existsSync();
  bool wanted(String id, bool detected) => only == null ? detected : only.contains(id);

  final targets = <EditorTarget>[];

  if (wanted('cursor', dir(joinPath(home, '.cursor')) || dir(project.path('.cursor')) || which('cursor') != null)) {
    targets.add(EditorTarget(
      id: 'cursor',
      name: 'Cursor',
      configPath: project.path(joinPath('.cursor', 'mcp.json')),
      serversKey: 'mcpServers',
    ));
  }

  final vscodeHome = dir(joinPath(home, '.vscode')) || dir(joinPath(home, '.vscode-insiders'));
  if (wanted('vscode', vscodeHome || dir(project.path('.vscode')) || which('code') != null)) {
    targets.add(EditorTarget(
      id: 'vscode',
      name: 'VS Code',
      configPath: project.path(joinPath('.vscode', 'mcp.json')),
      serversKey: 'servers',
      vscodeFormat: true,
    ));
  }

  // Antigravity 2 reads ~/.gemini/config/mcp_config.json; the first releases
  // read ~/.gemini/antigravity/mcp_config.json. Write whichever exist.
  final antigravityPaths = [
    joinPath(home, '.gemini', 'config'),
    joinPath(home, '.gemini', 'antigravity'),
  ];
  final antigravityFound = antigravityPaths.where(dir).toList();
  if (wanted('antigravity', antigravityFound.isNotEmpty || which('antigravity') != null)) {
    final folders = antigravityFound.isEmpty ? [antigravityPaths.first] : antigravityFound;
    for (final folder in folders) {
      targets.add(EditorTarget(
        id: 'antigravity',
        name: 'Antigravity',
        configPath: joinPath(folder, 'mcp_config.json'),
        serversKey: 'mcpServers',
        global: true,
      ));
    }
  }

  if (wanted('windsurf', dir(joinPath(home, '.codeium', 'windsurf')) || which('windsurf') != null)) {
    targets.add(EditorTarget(
      id: 'windsurf',
      name: 'Windsurf',
      configPath: joinPath(home, '.codeium', 'windsurf', 'mcp_config.json'),
      serversKey: 'mcpServers',
      global: true,
    ));
  }

  if (wanted('claude', dir(joinPath(home, '.claude')) || which('claude') != null)) {
    targets.add(EditorTarget(
      id: 'claude',
      name: 'Claude Code',
      configPath: project.path('.mcp.json'),
      serversKey: 'mcpServers',
    ));
  }

  final geminiCli = which('gemini') != null || File(joinPath(home, '.gemini', 'settings.json')).existsSync();
  if (wanted('gemini', geminiCli)) {
    targets.add(EditorTarget(
      id: 'gemini',
      name: 'Gemini CLI',
      configPath: project.path(joinPath('.gemini', 'settings.json')),
      serversKey: 'mcpServers',
      trust: true,
    ));
  }

  return targets;
}

/// fixkit's server entry for [target].
Map<String, Object?> fixkitServerEntry(EditorTarget target, Project project) {
  final launcher = target.vscodeFormat
      ? r'${workspaceFolder}/.fixkit/mcp.dart'
      : project.launcher.path;
  return {
    if (target.vscodeFormat) 'type': 'stdio',
    'command': dartExecutable(),
    'args': [launcher, if (target.global) '--global'],
    if (target.trust) 'trust': true,
  };
}

/// The Dart SDK's own MCP server (hot reload, widget tree, runtime errors).
Map<String, Object?> dartServerEntry(EditorTarget target) => {
      if (target.vscodeFormat) 'type': 'stdio',
      'command': dartExecutable(),
      'args': [
        'mcp-server',
        // Needed before Dart 3.9, when the server was experimental.
        if (!dartAtLeast(3, 9)) '--experimental-mcp-server',
        '--force-roots-fallback',
      ],
      if (target.trust) 'trust': true,
    };

/// Whether the config already has a Dart MCP server under any name.
bool hasDartServer(Map<String, Object?> servers) {
  for (final entry in servers.entries) {
    if (entry.key == 'dart') return true;
    final value = entry.value;
    if (value is Map && value['args'] is List && (value['args'] as List).contains('mcp-server')) return true;
  }
  return false;
}

/// What writing a config did.
class ConfigChange {
  const ConfigChange(this.target, {required this.wrote, this.addedDart = false, this.error});

  final EditorTarget target;
  final bool wrote;
  final bool addedDart;
  final String? error;
}

/// Adds or updates fixkit's entry (and the Dart MCP server, when missing) in
/// [target]'s config. Keeps everything else in the file as it was.
ConfigChange writeEditorConfig(EditorTarget target, Project project, {bool addDart = true, bool dryRun = false}) {
  try {
    final file = target.file;
    final original = file.existsSync() ? file.readAsStringSync() : '';
    var text = original;
    final decoded = decodeJsonc(text);
    final config = decoded is Map ? decoded.cast<String, Object?>() : <String, Object?>{};
    final servers = config[target.serversKey] is Map
        ? (config[target.serversKey] as Map).cast<String, Object?>()
        : <String, Object?>{};

    text = setJsoncValue(text, [target.serversKey, 'fixkit'], fixkitServerEntry(target, project));
    var addedDart = false;
    // VS Code gets the Dart server from the Dart extension's setting instead.
    if (addDart && !target.vscodeFormat && !hasDartServer(servers)) {
      text = setJsoncValue(text, [target.serversKey, 'dart'], dartServerEntry(target));
      addedDart = true;
    }

    if (text == original) return ConfigChange(target, wrote: false);
    if (!dryRun) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    }
    return ConfigChange(target, wrote: true, addedDart: addedDart);
  } catch (error) {
    return ConfigChange(target, wrote: false, error: '$error');
  }
}

/// Removes fixkit's entry from [target]'s config.
bool removeEditorConfig(EditorTarget target) {
  final file = target.file;
  if (!file.existsSync()) return false;
  final original = file.readAsStringSync();
  final text = removeJsoncValue(original, [target.serversKey, 'fixkit']);
  if (text == original) return false;
  file.writeAsStringSync(text);
  return true;
}

/// Whether [target]'s config has a fixkit entry whose launcher exists.
({bool present, bool valid, String? problem}) checkEditorConfig(EditorTarget target, Project project) {
  final file = target.file;
  if (!file.existsSync()) return (present: false, valid: false, problem: 'no config file');
  try {
    final decoded = decodeJsonc(file.readAsStringSync());
    final servers = decoded is Map ? decoded[target.serversKey] : null;
    final entry = servers is Map ? servers['fixkit'] : null;
    if (entry is! Map) return (present: false, valid: false, problem: 'no fixkit entry');
    final command = entry['command'];
    if (command is String && (command.contains('/') || command.contains(r'\')) && !File(command).existsSync()) {
      return (present: true, valid: false, problem: 'dart not found at $command; run init again');
    }
    final args = entry['args'];
    if (args is List && args.isNotEmpty && args.first is String) {
      final launcher = (args.first as String).replaceAll(r'${workspaceFolder}', project.root);
      if (!File(launcher).existsSync()) {
        return (present: true, valid: false, problem: 'launcher missing: $launcher');
      }
    }
    return (present: true, valid: true, problem: null);
  } catch (error) {
    return (present: false, valid: false, problem: 'unreadable: $error');
  }
}

/// `.vscode/settings.json`: the Dart extension's MCP server and hot reload on
/// save, which Cursor, Antigravity and Windsurf read as well. Leaves values
/// the person already set.
List<String> writeVscodeSettings(Project project, {bool dryRun = false}) {
  final file = project.file(joinPath('.vscode', 'settings.json'));
  final original = file.existsSync() ? file.readAsStringSync() : '';
  final decoded = decodeJsonc(original);
  final settings = decoded is Map ? decoded : const {};
  var text = original;
  final changed = <String>[];
  if (!settings.containsKey('dart.flutterHotReloadOnSave')) {
    text = setJsoncValue(text, ['dart.flutterHotReloadOnSave'], 'all');
    changed.add('hot reload on save');
  }
  if (!settings.containsKey('dart.mcpServer')) {
    text = setJsoncValue(text, ['dart.mcpServer'], true);
    changed.add('Dart MCP server');
  }
  if (changed.isNotEmpty && !dryRun) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }
  return changed;
}

/// `.claude/settings.local.json`: enables the project's MCP servers and
/// pre-approves fixkit's tools for Claude Code.
bool writeClaudeSettings(Project project, {required bool dart, bool dryRun = false}) {
  final file = project.file(joinPath('.claude', 'settings.local.json'));
  final original = file.existsSync() ? file.readAsStringSync() : '';
  final decoded = decodeJsonc(original);
  final settings = decoded is Map ? decoded : const {};

  final enabled = [
    ...(settings['enabledMcpjsonServers'] is List ? settings['enabledMcpjsonServers'] as List : const []),
  ];
  for (final name in ['fixkit', if (dart) 'dart']) {
    if (!enabled.contains(name)) enabled.add(name);
  }
  final permissions = settings['permissions'] is Map ? settings['permissions'] as Map : const {};
  final allow = [...(permissions['allow'] is List ? permissions['allow'] as List : const [])];
  if (!allow.contains('mcp__fixkit')) allow.add('mcp__fixkit');

  var text = setJsoncValue(original, ['enabledMcpjsonServers'], enabled);
  text = setJsoncValue(text, ['permissions', 'allow'], allow);
  if (text == original) return false;
  if (!dryRun) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }
  return true;
}

/// `.vscode/launch.json`: passes the Wi-Fi host and token to Flutter launches,
/// for phones that reach the computer over the network.
bool writeLanLaunchConfig(Project project, {bool dryRun = false}) {
  final file = project.file(joinPath('.vscode', 'launch.json'));
  const define = '--dart-define-from-file=.fixkit/defines.json';
  final original = file.existsSync() ? file.readAsStringSync() : '';
  final decoded = decodeJsonc(original);
  final launch = decoded is Map ? decoded : const {};
  final configurations = launch['configurations'] is List ? [...launch['configurations'] as List] : <Object?>[];

  var changed = false;
  if (configurations.isEmpty) {
    configurations.add({
      'name': project.name,
      'request': 'launch',
      'type': 'dart',
      'program': 'lib/main.dart',
      'toolArgs': [define],
    });
    changed = true;
  } else {
    for (var i = 0; i < configurations.length; i++) {
      final configuration = configurations[i];
      if (configuration is! Map || configuration['type'] != 'dart') continue;
      final toolArgs = [...(configuration['toolArgs'] is List ? configuration['toolArgs'] as List : const [])];
      if (toolArgs.contains(define)) continue;
      toolArgs.add(define);
      configurations[i] = {...configuration, 'toolArgs': toolArgs};
      changed = true;
    }
  }
  if (!changed) return false;
  var text = original;
  if (!launch.containsKey('version')) text = setJsoncValue(text, ['version'], '0.2.0');
  text = setJsoncValue(text, ['configurations'], configurations);
  if (!dryRun) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(text);
  }
  return true;
}
