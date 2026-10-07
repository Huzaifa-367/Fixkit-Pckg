/// fixkit: long press any widget in a debug build of your Flutter app, type
/// what is wrong, and the AI agent in your editor fixes it and hot reloads.
///
/// ```dart
/// import 'package:fixkit/fixkit.dart';
///
/// void main() => runApp(FixKit(child: MyApp()));
/// ```
///
/// Set up the editor side with `dart run fixkit init`.
library;

export 'src/app/connection.dart' show FixConnection, FixHubUnreachable, FixVersionMismatch;
export 'src/app/fixkit.dart' show FixKit;
export 'src/app/markers.dart' show FixName, FixScreen;
