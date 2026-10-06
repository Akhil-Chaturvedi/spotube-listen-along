import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart';

import '../../core/env.dart';
import 'common.dart';

class AndroidBuildCommand extends Command with BuildCommandCommonSteps {
  @override
  String get description => "Build for android";

  @override
  String get name => "android";

  @override
  FutureOr? run() async {
    await bootstrap();

    // Build ONLY for armeabi-v7a (32-bit ARM). This fork targets a single
    // 32-bit armv7a device, so a universal/fat APK is unnecessary and larger.
    await shell.run(
      "flutter build apk --flavor ${CliEnv.channel.name} --target-platform android-arm",
    );

    final ogApkFile = File(
      join(
        "build",
        "app",
        "outputs",
        "flutter-apk",
        "app-${CliEnv.channel.name}-release.apk",
      ),
    );

    await ogApkFile.copy(
      join(cwd.path, "build", "Spotube-android-armv7a.apk"),
    );

    stdout.writeln("✅ Built Android Apk (armeabi-v7a)");
  }
}
