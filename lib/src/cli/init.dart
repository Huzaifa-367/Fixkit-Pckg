import 'dart:convert';
import 'dart:io';

import '../protocol.dart';
import '../server/host_tools.dart';
import '../server/hub_client.dart';
import '../server/paths.dart';
import 'console.dart';
import 'editors.dart';
import 'jsonc.dart';
import 'main_patch.dart';
import 'project.dart';
import 'templates.dart';
import 'versions.dart';

/// `dart run fixkit init`: wires fixkit into the project and every editor on
/// the computer, then starts the hub.
Future<int> runInit(List<String> arguments, Console console) async {
  final dryRun = arguments.contains('--dry-run');
  // Run by `fixkit upgrade` with the new version: same work, shorter ending.
  final refresh = arguments.contains('--refresh');
  final lan = arguments.contains('--lan');
  final skipMain = arguments.contains('--no-main');
  final skipDart = arguments.contains('--no-dart-mcp');
  final only = _listOption(arguments, 'editors');

  final project = Project.find();
  if (project == null) {
    console.line('${console.red('✖')} No pubspec.yaml here or above. Run this in your Flutter project.');
    return 1;
  }
  console.title('fixkit init${dryRun ? ' (dry run: nothing is written)' : ''}  ${console.dim(project.root)}');

  if (!project.dependsOnFixkit) {
    console.fail('pubspec.yaml', 'fixkit is not a dependency yet.');
    console.hint('Run `flutter pub add fixkit`, then `dart run fixkit init` again.');
    return 1;
  }

  // After an upgrade: bring fixkit's own files up to date and restart the
  // hub. The app's code and the choice of editors stay as they were.
  if (refresh && !dryRun) {
    final changed = refreshProject(project);
    console.ok('Setup', changed.isEmpty ? 'up to date for $fixkitVersion' : 'refreshed ${changed.join(', ')}');
    await _ensureHub(project, console, lan: lan);
    console.line();
    console.line('  Reload your editor window so it starts the new fixkit MCP server.');
    console.line();
    return 0;
  }

  // 1. Wrap runApp.
  if (skipMain) {
    console.info('main.dart', 'skipped (--no-main)');
  } else {
    _wrapMain(project, console, dryRun: dryRun);
  }

  // 2. The launcher editors run.
  final launcher = project.launcher;
  final ignore = project.file(joinPath('.fixkit', '.gitignore'));
  final launcherChanged = !launcher.existsSync() || launcher.readAsStringSync() != launcherSource;
  if (!dryRun) {
    launcher.parent.createSync(recursive: true);
    if (launcherChanged) launcher.writeAsStringSync(launcherSource);
    if (!ignore.existsSync()) ignore.writeAsStringSync(fixkitGitignore);
  }
  console.ok('Launcher', '.fixkit/mcp.dart${launcherChanged ? '' : ' (up to date)'}');

  // 3. Editors.
  final editors = detectEditors(project, only: only);
  if (editors.isEmpty) {
    console.warn('Editors', 'none found; writing configs for Cursor and VS Code.');
    editors.addAll(detectEditors(project, only: {'cursor', 'vscode'}));
  }
  var claudeHasDart = false;
  for (final editor in editors) {
    final change = writeEditorConfig(editor, project, addDart: !skipDart, dryRun: dryRun);
    final where = editor.global ? _tilde(editor.configPath) : project.relative(editor.configPath);
    if (change.error != null) {
      console.fail(editor.name, '$where: ${change.error}');
      console.hint('Fix the file by hand, or add fixkit to it as shown in the README.');
      continue;
    }
    final extras = [
      if (change.addedDart) '+ Dart MCP server',
      if (editor.global) 'all projects',
    ];
    console.ok(editor.name, '$where${change.wrote ? '' : ' (up to date)'}${extras.isEmpty ? '' : '  ${console.dim(extras.join(', '))}'}');
    if (editor.id == 'claude') {
      final decoded = decodeJsonc(editor.file.existsSync() ? editor.file.readAsStringSync() : '');
      final servers = decoded is Map ? decoded['mcpServers'] : null;
      claudeHasDart = servers is Map && servers.containsKey('dart');
    }
  }

  // 4. Hot reload on save and the Dart extension's MCP server, read by VS Code
  //    and the editors built on it.
  final usesDartExtension = editors.any((editor) => ['vscode', 'cursor', 'antigravity', 'windsurf'].contains(editor.id));
  if (usesDartExtension) {
    try {
      final changed = writeVscodeSettings(project, dryRun: dryRun);
      console.ok('Hot reload', changed.isEmpty ? 'on save (already set)' : '.vscode/settings.json: ${changed.join(', ')}');
    } catch (error) {
      console.warn('Hot reload', 'could not update .vscode/settings.json: $error');
    }
  }

  // 5. Claude Code: enable the project's servers and pre-approve fixkit.
  if (editors.any((editor) => editor.id == 'claude')) {
    try {
      writeClaudeSettings(project, dart: claudeHasDart, dryRun: dryRun);
      console.ok('Claude Code', '.claude/settings.local.json: fixkit tools pre-approved');
    } catch (error) {
      console.warn('Claude Code', 'could not update .claude/settings.local.json: $error');
    }
  }

  // 6. Agent rules.
  final rules = <String>['AGENTS.md'];
  if (editors.any((editor) => editor.id == 'claude') || project.file('CLAUDE.md').existsSync()) rules.add('CLAUDE.md');
  if (project.file('GEMINI.md').existsSync()) rules.add('GEMINI.md');
  if (project.file(joinPath('.github', 'copilot-instructions.md')).existsSync()) {
    rules.add('.github/copilot-instructions.md');
  }
  for (final name in rules) {
    final file = project.file(name);
    final existing = file.existsSync() ? file.readAsStringSync() : null;
    final updated = withAgentsSection(existing);
    if (!dryRun && updated != existing) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(updated);
    }
  }
  console.ok('Agent rules', rules.join(', '));

  // 7. Phones on Wi-Fi.
  if (lan) {
    if (!dryRun) {
      FixkitSettings.load().copyWith(lan: true).save();
      await _writeDefines(project);
      writeLanLaunchConfig(project);
    }
    console.ok('Wi-Fi devices', 'on: launches pass the host and token (.fixkit/defines.json)');
  }

  // 8. The version this setup was made with; a later fixkit refreshes it.
  if (!dryRun) {
    final previous = readStamp(project);
    // A stamp from a newer fixkit (a teammate's) is left alone.
    if (previous == null || !(previous > currentVersion)) writeStamp(project);
    if (previous != null && previous > currentVersion) {
      console.warn('Version', 'this setup was made with fixkit $previous, newer than $fixkitVersion: run `dart run fixkit upgrade`');
    } else if (previous != null && previous != currentVersion) {
      console.ok('Version', 'setup moved from $previous to $fixkitVersion');
    } else {
      console.ok('Version', 'fixkit $fixkitVersion  ${console.dim('(.fixkit/state.json)')}');
    }
  }

  // 9. The hub.
  if (!dryRun) await _ensureHub(project, console, lan: lan);

  final adb = HostTools().findAdb();
  if (adb == null) {
    console.info('Android', 'adb not found: devices reach the hub through the emulator address only');
  }

  console.line();
  console.line(console.bold('Next'));
  console.line('  1. Reload your editor window once, so it loads the fixkit MCP server.');
  console.line('     ${console.dim('Cursor/VS Code may ask you to enable or start it; Claude Code asks to approve .mcp.json.')}');
  console.line('  2. Run the app as usual (F5, or `flutter run`) on a simulator, emulator or phone.');
  console.line('  3. In your agent chat, say:  ${console.cyan('watch for fixes')}');
  console.line('  4. Long press anything in the app, type what is wrong, press Send.');
  console.line();
  console.line(console.dim('  `dart run fixkit doctor` checks every piece. `dart run fixkit uninstall` undoes this.'));
  console.line();
  return 0;
}

Future<void> _ensureHub(Project project, Console console, {required bool lan}) async {
  try {
    final hub = HubClient(entryScript: project.launcher.path);
    final hello = await hub.ensure(restartIfLanDiffers: lan);
    hub.close();
    console.ok('Hub', 'fixkit ${hello['version']} on ${hello['lan'] == true ? 'all interfaces' : '127.0.0.1'}, port 4747');
  } catch (error) {
    console.warn('Hub', 'not started yet: $error');
    console.hint('Your editor starts it when it loads fixkit.');
  }
}

void _wrapMain(Project project, Console console, {required bool dryRun}) {
  final entries = project.entryPoints.where((file) => hasRunApp(file.readAsStringSync())).toList();
  if (entries.isEmpty) {
    console.warn('main.dart', 'no runApp(...) found in lib/main*.dart');
    console.hint('Wrap your app yourself: runApp(FixKit(child: MyApp()))');
    return;
  }
  for (final file in entries) {
    final name = project.relative(file.path);
    final result = wrapRunApp(file.readAsStringSync());
    if (result.alreadyDone) {
      console.ok(name, 'already wraps runApp in FixKit');
    } else if (result.changed) {
      if (!dryRun) file.writeAsStringSync(result.source);
      console.ok(name, 'runApp(FixKit(child: ...)) ${console.dim('(does nothing in release builds)')}');
    } else {
      console.warn(name, 'could not change runApp(...) automatically');
      console.hint('Wrap your app yourself: runApp(FixKit(child: MyApp()))');
    }
  }
}

/// `.fixkit/defines.json`: what Flutter launches pass to the app so a phone on
/// Wi-Fi finds the hub.
Future<void> _writeDefines(Project project) async {
  final address = await HostTools().lanAddress();
  final file = project.file(joinPath('.fixkit', 'defines.json'));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'FIXKIT_HOST': address == null ? '' : '$address:4747',
    'FIXKIT_TOKEN': lanToken(),
  }));
}

/// `dart run fixkit uninstall`: undoes init.
Future<int> runUninstall(List<String> arguments, Console console) async {
  final project = Project.find();
  if (project == null) {
    console.line('${console.red('✖')} No pubspec.yaml here or above.');
    return 1;
  }
  console.title('fixkit uninstall  ${console.dim(project.root)}');

  for (final file in project.entryPoints) {
    final result = unwrapFixKit(file.readAsStringSync());
    if (result.changed) {
      file.writeAsStringSync(result.source);
      console.ok(project.relative(file.path), 'removed FixKit');
    }
  }

  for (final editor in detectEditors(project, only: allEditorIds.toSet())) {
    if (!editor.file.existsSync()) continue;
    try {
      if (removeEditorConfig(editor)) {
        console.ok(editor.name, 'removed fixkit from ${editor.global ? _tilde(editor.configPath) : project.relative(editor.configPath)}');
      }
    } catch (error) {
      console.warn(editor.name, '$error');
    }
  }

  final claude = project.file(joinPath('.claude', 'settings.local.json'));
  if (claude.existsSync()) {
    try {
      final original = claude.readAsStringSync();
      final decoded = decodeJsonc(original);
      if (decoded is Map) {
        var text = original;
        final enabled = decoded['enabledMcpjsonServers'];
        if (enabled is List && enabled.contains('fixkit')) {
          text = setJsoncValue(text, ['enabledMcpjsonServers'], [...enabled]..remove('fixkit'));
        }
        final permissions = decoded['permissions'];
        final allow = permissions is Map ? permissions['allow'] : null;
        if (allow is List && allow.contains('mcp__fixkit')) {
          text = setJsoncValue(text, ['permissions', 'allow'], [...allow]..remove('mcp__fixkit'));
        }
        if (text != original) {
          claude.writeAsStringSync(text);
          console.ok('Claude Code', 'removed fixkit from .claude/settings.local.json');
        }
      }
    } catch (_) {}
  }

  for (final name in ['AGENTS.md', 'CLAUDE.md', 'GEMINI.md', '.github/copilot-instructions.md']) {
    final file = project.file(name);
    if (!file.existsSync()) continue;
    final text = file.readAsStringSync();
    final updated = withoutAgentsSection(text);
    if (updated == text) continue;
    if (updated.trim().isEmpty) {
      file.deleteSync();
    } else {
      file.writeAsStringSync(updated);
    }
    console.ok(name, 'removed the fixkit section');
  }

  final dir = Directory(project.path('.fixkit'));
  if (dir.existsSync()) {
    dir.deleteSync(recursive: true);
    console.ok('.fixkit/', 'deleted (launcher, reports, screenshots)');
  }

  console.line();
  console.line('  Finally: ${console.cyan('flutter pub remove fixkit')}');
  console.line(console.dim('  .vscode/settings.json keeps hot reload on save and the Dart MCP server; remove them if you like.'));
  console.line();
  return 0;
}

Set<String>? _listOption(List<String> arguments, String name) {
  for (final argument in arguments) {
    if (argument.startsWith('--$name=')) {
      final values = argument.substring(name.length + 3).split(',').map((value) => value.trim().toLowerCase());
      return values.where((value) => value.isNotEmpty).toSet();
    }
  }
  return null;
}

String _tilde(String path) {
  final home = homeDirectory();
  return path.startsWith(home) ? '~${path.substring(home.length)}' : path;
}
